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
  #:export (newer))

(define (get-mtime-ns file)
  (and (file-exists? file)
       (let ((s (stat file)))
         (+ (* (stat:mtime s) 1000000000)
            (stat:mtimensec s)))))

(define (get-sources-mtime-ns l)
  (let ((t (get-mtime-ns (car l))))
    (cond ((null? (cdr l))     t)
          (t                   (max t (get-sources-mtime-ns (cdr l))))
          (#t                  #f))))

(define (newer a b)
  #f)
