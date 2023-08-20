(import (srfi srfi-64)
        (ice-9 threads)
        (core)
        (lib))

(define log-lock (make-mutex))
(define log '())

(define (log-msg msg)
  (with-mutex log-lock
    (set! log (cons msg log))))

(define (wrapper . body)
  (set! log '())
  (begin body))

(defc (simple-success)
  #t)

(test-begin "core")
(test-equal #t
  (satisfy-run (simple-success) #:jobs 1))

(define error-count (test-runner-fail-count (test-runner-current)))
(test-end "core")

(exit error-count)
