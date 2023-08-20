(define-module (core)
  #:export (defc sat satisfy-run msg debug))

(use-modules (srfi srfi-9) ; records
             (rnrs exceptions)
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

;;;;;;;;; Loop wrapper
(define (loop-wrapper name thunk)
  (catch #t
    thunk
    (lambda args (exit 1))
    (lambda args
      (with-mutex plock
        (format (current-error-port) "Internal error in ~a ~a" name args)
        (backtrace)))))

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

;; #t -> resolved
;; #f -> unknown
;; 'failed
(define (task-outcome con)
  (hash-ref resolved--tab (ckey con)))

(define (set-resolved! key)
  (hash-set! resolved--tab key #t))

(define (set-failed! key)
  (hash-set! resolved--tab key 'failed))

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
  (mailbox! runq `(newdep ,requirement . ,conts)))

(define (require! requirement)
  (unless (task-outcome requirement)
    (depend! requirement '())))

(define (worker-ready! worker-id)
  (mailbox! runq `(worker-ready . ,worker-id)))

(define (resolved! key)
  (mailbox! runq `(resolved . ,key)))

(define (failed! key exn args)
  (mailbox! runq `(failed ,key ,exn . ,args)))

;;;;;;;; Worker

(define (task-exn-handler exn . args)
  (format (current-error-port)
          "Task failed: ~s ~a\n" exn (list args)))

(define (exec-task task)
  (task))

(define (worker-loop id mbox)
  (dbg "Worker loop ~a\n" id)
  (worker-ready! id)
  (let ((tasks (mailbox-receive mbox)))
    (for-each exec-task tasks))
  (worker-loop id mbox))

(define (worker-entrypoint id mbox)
  (loop-wrapper (list 'worker id)
   (lambda () (worker-loop id mbox))))

(define-record-type worker
  (make--worker thread mailbox idle)
  worker?
  (thread w:thread)
  (mailbox w:mailbox)
  (idle idle? set-idle!))

(define (make-worker id)
  (let* ((mailbox (make-mailbox id))
         (thread  (begin-thread (worker-entrypoint id mailbox))))
    (make--worker thread mailbox #f)))

(define (start-workers arg)
  (list->array 1
               (map make-worker (iota arg))))

(define (dispatch-to-worker! workers id task)
  (dbg "Dispatch ~a to ~a\n" task id)
  (mailbox! (w:mailbox (array-ref workers id))
            task))

(define (find-idle-worker workers)
  (let ((i 0)
        (n-workers (array-length workers)))
    ;; Loop over workers until we find an idle one:
    (while (and (< i n-workers)
                (not (idle? (array-ref workers i))))
      (++ i))
    ;; Found?
    (if (< i n-workers) i #f)))

(define (push-worker! workers id)
  (set-idle! (array-ref workers id) #t))

(define (pop-worker! workers)
  (let ((id (find-idle-worker workers)))
    (set-idle! (array-ref workers id) #f)
    id))

;;;;;;; Main process

(define (idle-workers? workers)
  (and (find-idle-worker workers) #t))

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

(define (dispatch-tasks workers)
  (while (and (planned-tasks?) (idle-workers? workers))
    (dispatch-to-worker! workers
                         (pop-worker! workers)
                         (pop-task!))))

;;;;; Wrapper for a condition:

(define (condition-shim con)
  (let* ((key (ckey con))
         (fun (cfun con))
         (handler (lambda (exn . args)
                    (failed! key exn args)))
         (pre-unwind (lambda (exn . args)
                       (with-mutex plock (backtrace)))))
    (lambda ()
      (catch #t
        (lambda ()
          (reset
           (dbg "~a is scheduled\n" key)
           (fun)
           (dbg "~a is satisfied\n" key)
           (resolved! key)))
        handler))))
        ;pre-unwind))))

;;;;; Main process:

(define failed? #f)

(define (handle-event workers event)
  (dbg "           ~a   ~a" event n-deps)
  ;; Process event:
  (match event
    ;; A task has been resolved:
    (`(resolved . ,key)
     (apply add-tasks! (pop-dep! key))
     (set-resolved! key))

    ;; A task has failed:
    (`(failed ,key ,exn . ,args)
     (with-mutex plock
       (format (current-error-port) "Task ~a failed: ~s (~a)\n" key exn (list args)))
     (set! failed? #t)
     (pop-dep! key))

    ;; Add a dependency:
    (`(newdep ,requirement . ,conts)
     (match (task-outcome requirement)
       ;; Already solved, dispatch immediately:
       (#t      (apply add-tasks! conts))

       ;; Add to the dependency list:
       (#f      (when (add-dep! requirement conts)
                  ;; This is a new task, schedule it for execution:
                  (add-tasks! (condition-shim requirement))))
       ;; Requirement has failed, so we ignore the new tasks:
       ('failed #t)))

    ;; Worker is ready:
    (`(worker-ready . ,worker-id)
     (push-worker! workers worker-id)))
  ;; Dispatch tasks to workers:
  (dispatch-tasks workers))

(define (main-loop workers)
  (for-each (lambda (evt) (handle-event workers evt))
            (mailbox-receive runq))
  (if (or (> n-deps 0) (planned-tasks?))
      ;; Then
      (main-loop workers)
      ;; Else:
      (not failed?)))

(define* (satisfy-run seed #:key
                      (jobs #f)
                      (debug #f))
  (dbg "Running ~a -j ~a" seed jobs)
  (loop-wrapper 'main
   (lambda ()
     ;; Initialize
     (set! satisfy--debug debug)
     (let ((workers (start-workers jobs)))
       ;; Enqueue the seed task:
       (require! seed)
       (main-loop workers)))))

;;;;;;;;;;;;; Client side

(define-syntax defc
  (syntax-rules ()
    ((_ (name args ...) body ...)
     (define (name args ...)
       (make-condition
        (list 'name args ...)
        (lambda () body ...))))))

(define (sat1 requirement)
  (unless (task-outcome requirement)
    (shift cont
           (depend! requirement (list cont)))))

(define (sat . reqs)
  ;; Pre-schedule the tasks:
  (for-each require! reqs)
  ;; Maybe block:
  (for-each sat1 reqs)
  ;; Return key(s):
  (map ckey reqs))
