(define-module (core)
  #:export (defc sat satisfy-run msg debug))

(use-modules (srfi srfi-9) ; records
             (ice-9 threads)
             (ice-9 control)
             (ice-9 q)
             (ice-9 match)
             (ice-9 format))

(define plock (make-mutex))

(define-syntax ++
  (syntax-rules ()
    ((_ n)    (set! n (1+ n)))))

(define-syntax --
  (syntax-rules ()
    ((_ n)    (set! n (1- n)))))

(define (msg fmt . args)
  (with-mutex plock
    (apply format (append (list #t (string-append fmt "\n")) args))))

(define satisfy--debug #f)

(define (dbg fmt . args)
  (when satisfy--debug
    (apply msg (cons fmt args))))

(setvbuf (current-output-port) 'line)

;;;;;;;;; Mailbox

(define-record-type condition
  (make-condition key thunk)
  condition?
  (key ckey)
  (thunk cfun))

(define-record-type mailbox
  (make--mailbox-int name queue lock cvar)
  mailbox?
  (name mname)
  (queue mqueue set-mqueue!)
  (lock mlock)
  (cvar mcvar))

(define (make-mailbox name)
  (make--mailbox-int name
                     '()
                     (make-mutex)
                     (make-condition-variable)))

(define (drain-queue q)
  (let ((msgs (mqueue q)))
    (set-mqueue! q '())
    msgs))

(define (mailbox-receive box)
  (dbg "Receiving ~a" (mname box))
  (lock-mutex (mlock box))
  ;; Wait for the new messages, unless we already got some:
  (when (null? (mqueue box))
    (wait-condition-variable (mcvar box) (mlock box) ))
  ;; Drain the queue:
  (let ((msgs (drain-queue box)))
    (unlock-mutex (mlock box))
    msgs))

(define (mailbox! box message)
  (dbg "~a ! ~a" (mname box) message)
  (with-mutex (mlock box)
    (set-mqueue! box (cons message (mqueue box)))
    (signal-condition-variable (mcvar box)))
  message)

;;;;;;;;;;; Resolved memo tab
(define resolved--tab (make-hash-table))

(define (resolved? con)
  (hash-ref resolved--tab (ckey con)))

(define (set-resolved! key)
  (hash-set! resolved--tab key #t))

;;;; Deps tab
(define deps--tab (make-hash-table))
(define n-deps 0)

(define (pop-dep! key)
  (let ((conts (hash-ref deps--tab key '())))
    (hash-remove! deps--tab key)
    (-- n-deps)
    conts))

;; Returns #t if the `con' is a new task that hasn't been scheduled
;; for execution:
(define (add-dep! con conts)
  (let* ((key        (ckey con))
         (old-conts  (hash-ref deps--tab key)))
    (if old-conts
        ;; We have seen this condition:
        (begin
          (hash-set! deps--tab key (append conts old-conts))
          #f)
        ;; This one is new:
        (begin
          (++ n-deps)
          (hash-set! deps--tab key conts)
          #t))))

;;;;;;;; Runq

(define runq (make-mailbox 'runq))

;;;; Send messages:
(define (depend! requirement conts)
  (mailbox! runq `(depend ,requirement . ,conts)))

(define (require! requirement)
  (unless (resolved? requirement)
    (depend! requirement '())))

(define (worker-ready! worker-id)
  (mailbox! runq `(worker-ready . ,worker-id)))

(define (resolved! key)
  (mailbox! runq `(resolved . ,key)))

;;;;;;;; Worker

(define (worker-loop id mbox)
  (dbg "Worker loop ~a\n" id)
  (worker-ready! id)
  (let ((tasks (mailbox-receive mbox)))
    (for-each
     (lambda (task)
       (dbg "      ~a: executes ~a\n" id task)
       (task)
       (dbg "      ~a: is ready\n" id))
     tasks))
  (worker-loop id mbox))

(define idle-workers)
(define workers)

(define (start-workers n-workers)
  (let ((l '()))
    ;; Start workers:
    (do ((i 0 (1+ i)))
        ((>= i n-workers))
      (let ((mbox (make-mailbox i)))
        (begin-thread
         (worker-loop i mbox))
        (set! l (cons mbox l))))
    ;; Return an array:
    (set! workers (list->array 1 l))
    (set! idle-workers (make-array #f n-workers))))

(define (dispatch-to-worker! id task)
  (dbg "Dispatch ~a to ~a\n" task id)
  (mailbox! (array-ref workers id) task))

;;;;;;; Main process

;;;;; Pool of idle workers:

(define (find-idle-worker)
  (let ((i 0)
        (n-workers (array-length workers)))
    (while (and (< i n-workers)
                (not (array-ref idle-workers i)))
      (set! i (1+ i)))
    (if (< i n-workers)
        i
        #f)))

(define (push-worker! id)
  (array-set! idle-workers #t id))

(define (pop-worker!)
  (let ((id (find-idle-worker)))
    (array-set! idle-workers #f id)
    id))

(define (idle-workers?)
  (and (find-idle-worker) #t))

;;;;; Task queue:
(define task-queue (make-q))
(define n-planned 0)

(define (add-tasks! . tasks)
  (for-each (lambda (i)
              (enq! task-queue i))
            tasks))

(define (planned-tasks?)
  (not (q-empty? task-queue)))

(define (pop-task!)
  (q-pop! task-queue))

(define (dispatch-tasks)
  (while (and (planned-tasks?) (idle-workers?))
    (dispatch-to-worker! (pop-worker!)
                         (pop-task!))))

;;;;; Wrapper for a condition:

(define (condition-shim con)
  (let ((key (ckey con))
        (fun (cfun con)))
    (lambda ()
      (reset
       (dbg "~a is scheduled\n" key)
       (fun)
       (dbg "~a is satisfied\n" key)
       (resolved! key)))))

;;;;; Main process:

(define (handle-event event)
  (dbg "           ~a   ~a" event n-deps)
  ;; Process event:
  (match event
    ;; A task has been resolved:
    (`(resolved . ,key)
     (apply add-tasks! (pop-dep! key))
     (set-resolved! key))
    ;; Add a dependency:
    (`(depend ,requirement . ,conts)
     (if (resolved? requirement)
         ;; Already solved, dispatch immediately:
         (begin
           (apply add-tasks! conts))
         ;; Add to the dependency list:
         (begin
           (when (add-dep! requirement conts)
             ;; This is a new task, schedule it for execution
             (add-tasks! (condition-shim requirement))))))
    ;; Worker is ready:
    (`(worker-ready . ,worker-id)
     (push-worker! worker-id)))
  ;; Dispatch tasks to workers:
  (dispatch-tasks))

(define (main-loop)
  (for-each handle-event
            (mailbox-receive runq))
  (when (or (> n-deps 0) (planned-tasks?))
    (main-loop)))

(define* (satisfy-run seed #:key
                      (jobs #f)
                      (debug #f))
  (dbg "Running ~a -j ~a" seed jobs)
  ;; Initialize
  (set! satisfy--debug debug)
  (start-workers (or jobs
                     (current-processor-count)))
  ;; Enqueue the seed task:
  (require! seed)
  (main-loop))

;;;;;;;;;;;;; Client side

(define-syntax defc
  (syntax-rules ()
    ((_ name (args ...) body ...)
     (define (name args ...)
       (make-condition
        (list 'name args ...)
        (lambda () body ...))))))

(define (sat1 requirement)
  (unless (resolved? requirement)
    (shift cont
           (depend! requirement (list cont)))))

(define (sat . reqs)
  ;; Pre-schedule the tasks:
  (for-each require! reqs)
  ;; Maybe block:
  (for-each sat1 reqs)
  ;; Return key(s):
  (map ckey reqs))
