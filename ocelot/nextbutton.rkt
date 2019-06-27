#lang rosette

(require br/datum)
(require ocelot)

(provide model->constraints bind-universe mk-rel get-model get-next-model)

(define prev-constraints null)

; Provides a syntax for defining a universe of discourse an binding each atom
; to a singleton relation.  These relations aren't exposed to the forge user
; but are used to parse a model back into constraints
(define-syntax (bind-universe stx)
  (syntax-case stx ()
    [(_ u bound singletons (id ...)) #'(begin
                              (define lst (list 'id ...))
                              (define-values (u id ...) (values (universe '(id ...)) (declare-relation 1 (string-append "atomic-" (symbol->string 'id))) ...))
                              (define singletons (list (list 'id id) ...))
                              (define bound (map (lambda (x y) (make-exact-bound x (format-datum `((~a)) y))) (list id ...) lst)))]))

; Helper that wraps the ocelot 'and' macro into a function for unrolling
(define (sneaky-and l r)
  (and l r))

; Takes an ocelot model (#hash from relations to lists of tuples) and raturns
; a list of constraints
(define (model->constraints hashy singletons)
  (define constraints (map (lambda (rel)
         (map (lambda (tuple)
                (in (mk-rel tuple singletons) rel)) (hash-ref hashy rel))) (hash-keys hashy)))
  (! (foldl sneaky-and (= none none) (flatten constraints))))

(define (sym-to-sin-func singletons)
  (define (sym-to-sin sym)
    (define filtered (filter (lambda (x) (eq? (car x) sym)) singletons))
    (car (cdr (car filtered))))
  sym-to-sin)

(define (mk-rel tuple singletons)
  (define sts (sym-to-sin-func singletons))
  (define ret
  (case (length tuple)
    ([1] (sts (car tuple)))
    (else (apply -> (map sts tuple)))))
  ret)

; Gets the current (or initial) model and caches it as constraints
(define (get-model constraints model-bounds singletons)
  (assert (interpret* constraints model-bounds))
  (define model (interpretation->relations (evaluate model-bounds (solve (assert #t)))))
  (if (equal? null prev-constraints)
      (begin (set! prev-constraints (interpret* (model->constraints model singletons) model-bounds)) model) model))

; Gets the next model and caches it as constraints
(define (get-next-model model-bounds singletons)
  (assert prev-constraints)
  (define model (interpretation->relations (evaluate model-bounds (solve (assert #t)))))
  (set! prev-constraints (interpret* (model->constraints model singletons) model-bounds))
  model)
