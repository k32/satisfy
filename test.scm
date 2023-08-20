;; This program is free software: you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation version 3 of the License.
;;
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program. If not, see
;; <https://www.gnu.org/licenses/>.

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

(defc (simple-fail)
  (1)
  #t)

(test-begin "core")
(test-equal #t (satisfy-run (simple-success) #:jobs 10))
(test-equal #t (satisfy-run (simple-success)))
(test-equal #f (satisfy-run (simple-fail) #:jobs 10))

(define error-count (test-runner-fail-count (test-runner-current)))
(test-end "core")

(exit error-count)
