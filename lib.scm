(define-module (lib)
  #:export (newer))

(define (compare-mtime a b)
  (let* ((s_a (stat a))
         (s_b (stat b))
         (t_a (stat:mtime s_a))
         (t_b (stat:mtime s_b)))
    (cond
     ((> t_a t_b) #t)
     ((< t_a t_b) #f)
     ((= t_a t_b)
      (>= (stat:mtimesec s_a) (stat:mtimesec s_b))))))


;(compare-mtime "~/.emacs.d/init.el" "~/.emacs.d/init.el")


(define (newer target source)
  ;; TODO
  #f)
