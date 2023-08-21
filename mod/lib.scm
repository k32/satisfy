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

(define-module (lib)
  #:export (newer? default-shell shell! always-make))

(define always-make #f)

(define (get-mtime-ns file)
  (and (file-exists? file)
       (let ((s (stat file)))
         (+ (* (stat:mtime s) 1000000000)
            (stat:mtimensec s)))))

(define (get-sources-mtime-ns l)
  (let* ((hd   (car l))
         (tl   (cdr l))
         (t    (get-mtime-ns hd)))
    (cond ((not t)            (throw 'missing-source-file hd))
          ((null? tl)         t)
          (#t                 (max t (get-sources-mtime-ns tl))))))

(define (get-targets-mtime-ns l)
  (let* ((hd   (car l))
         (tl   (cdr l))
         (t    (get-mtime-ns hd)))
    (cond ((not t)            #f)
          ((null? tl)         t)
          (#t                 (min t (get-targets-mtime-ns tl))))))

(define (newer? target . sources)
  (let* ((targets (if (string? target)
                      (list target)
                      target))
         (tmt (get-targets-mtime-ns targets)))
    (and tmt
         (> tmt (get-sources-mtime-ns sources))
         (not always-make))))

(define (shell! . chunks)
  "Execute a shell command and throw an exception if the return code is
not 0"
  (let* ((cmd         (apply string-append chunks))
         (exit-code   (system cmd)))
    (unless (= 0 exit-code)
      (throw 'recipe-failed cmd exit-code))))
