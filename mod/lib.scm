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
