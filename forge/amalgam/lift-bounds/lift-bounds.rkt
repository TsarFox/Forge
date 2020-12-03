#lang forge/core
(require (prefix-in @ racket))

; Bounds lifting functions for Amalgam
; expression x bounds -> bounds

; Every Kodkod problem has (upper, lower) bounds for every relation.
; Amalgam needs to have safe bounds estimates for every *expression*
;  since I might write some x : A+B, I need to know the upper-bound for
;   A+B in order to turn the quantified formula into a big "or".
; One thing we might do is just use univ (of appropriate arity), but
;  that gets very large and unwieldy quite quickly. E.g.,
;    suppose UB(A) = {A0, A1}, UB(B) = {B0, B1},
;            UB(C) = {C0, C1, C2}, UB(Int) = [-8, ..., 7].
;   Then if we convert the above quantified formula using "univ", we'll build
;    a big "or" with *23* disjuncts, rather than the *4* needed (note C wasn't included).
;  Also, the desugaring algorithm uses upper-bounds in a lot of other places,
;    e.g., "R in Q" becomes a big "and" saying that all possible members of R
;    are in Q (if they are in R).
;
;  We therefore need this function to "lift" the notion of bounds on a relation
;   to arbitrary expressions.

; Adapted from original Amalgam UpperBoundVisitor.java at:
; https://github.com/transclosure/amalgam/blob/master/src/edu/mit/csail/sdg/alloy4compiler/translator/AmalgamUpperBoundVisitor.java

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(provide lift-bounds-expr)
(require "lift-bounds_helpers.rkt")
(require debug/repl)
;;;;;;;;;;;;;;;;;;;;;;;;;

; Only Expression and IntExpression cases needed
; (we never try to lift bounds of a formula, because that makes no sense.)
;  ... -> list<tuple> i.e., list<list<atom>> (note atom NOT EQUAL TO atom expression)
(define (lift-bounds-expr expr quantvars runContext)

  (match expr

    ; atom case (base case)
    [(node/expr/atom info arity name)
     (printf "lift-bounds atom base case ~a~n" expr)
     ; node/expr/atom -> atom  (actual atom, i.e. symbol)
     (define tuple (list (node/expr/atom-name expr)))
     (list tuple)]
    
    ; relation name (base case)
    [(node/expr/relation info arity name typelist parent isvar)
     (printf "lift-bounds relation name base case ~n")
     (define all-bounds (forge:Run-kodkod-bounds runContext)) ; list of bounds objects     
     (define filtered-bounds (filter (lambda (b) (equal? name (forge:relation-name (forge:bound-relation b)))) all-bounds))
     (cond [(equal? (length filtered-bounds) 1) (forge:bound-upper (first filtered-bounds))]
           [else (error (format "lift-bounds-expr on ~a: didn't have a bound for ~a in ~a" expr name all-bounds))])]

    ; The Int constant
    [(node/expr/constant info 1 'Int)
     (printf "lift-bounds int constant base case ~n")
     (define all-bounds (forge:Run-kodkod-bounds runContext)) ; list of bounds objects
     (define filtered-bounds (filter (lambda (b) (equal? "Int" (forge:relation-name (forge:bound-relation b)))) all-bounds))
     (cond [(equal? (length filtered-bounds) 1) (forge:bound-upper (first filtered-bounds))]
           [else (error (format "lift-bounds-expr on ~a: didn't have a bound for ~a in ~a" expr "Int" all-bounds))])]

    ; other expression constants
    [(node/expr/constant info arity type)
     (printf "lift-bounds other expression constants base case ~n")
     (cond
       [(equal? type 'univ) (map (lambda (x) (list x x)) (forge:Run-atoms runContext))]
       [(equal? type 'iden) (map (lambda (x) (list x x)) (forge:Run-atoms runContext))]
       [(equal? type 'none) '()])]
    
    ; expression w/ operator (union, intersect, ~, etc...)
    [(node/expr/op info arity args)
     (lift-bounds-expr-op expr quantvars args runContext)]
    
    ; quantified variable
    [(node/expr/quantifier-var info arity sym)
     (error (format "We should not be getting the bounds of a quantified variable ~a" sym))
     (printf "lift-bounds quantified variable  ~a~n" sym)]
    
    ; set comprehension e.g. {n : Node | some n.edges}
    [(node/expr/comprehension info len decls form)
     (printf "lift-bounds set comprehension ~n")
     
     (define vars (map car decls)) ; account for multiple variables  
     (let ([quantvars (append vars quantvars)])             
       ; {x: e1, y: e2 | ...}
       ; then UB(e1)->UB(e2) is the UB of the whole comprehension
       (define uppers
         (map (lambda (d)                                    
                (lift-bounds-expr (cdr d) quantvars runContext)) decls))
       ; Return a list of lists with all of the bounds with the cartesian product
       (map (lambda (ub) (apply append ub)) (apply cartesian-product uppers)))]))

(define (lift-bounds-expr-op expr quantvars args runContext)
  (match expr

    ; SET UNION 
    [(? node/expr/op/+?)
     (printf "lift-bounds +~n")
     ; The upper bound of the LHS and RHS is just the addition between both bounds  
     (define uppers 
       (map (lambda (arg)
              (lift-bounds-expr arg quantvars runContext)) args))
     ; We are assuming that uppers is a list of list of list of atoms 
     ; therefore, by calling 'apply', we can convert this into a list of list of atoms. 
     (remove-duplicates (apply append uppers))]
    
    ; SET MINUS 
    [(? node/expr/op/-?)
     (printf "lift-bounds -~n")
     ; Upper bound of A-B is A's upper bound (in case B empty).
     (lift-bounds-expr (first args) quantvars runContext)]

    ; SET INTERSECTION
    [(? node/expr/op/&?)
     (printf "lift-bounds &~n")
     (define upper-bounds
       (map (lambda (arg)
              (lift-bounds-expr arg quantvars runContext)) args))
     ; filter to filter out the LHS only if they are also in upper bounds of RHS
     (filter (lambda (x) (member x (first upper-bounds))) (apply append (rest upper-bounds)))]

    ; PRODUCT
    [(? node/expr/op/->?)
     (printf "lift-bounds ->~n")
     ; the bounds of A->B are Bounds(A) x Bounds(B)
     (define uppers 
       (map (lambda (arg)
              (lift-bounds-expr arg quantvars runContext)) args))     
     ; Return a list of lists with all of the bounds with the cartesian product
     (map (lambda (ub) (apply append ub)) (apply cartesian-product uppers))]

    ; JOIN
    [(? node/expr/op/join?)
     (printf "lift-bounds .~n")
     ; In order to approach a join with n arguments, we will first do a
     ; binary join and procede with a foldl doing a join on the previous
     ; result of the function
     (cond
       [(@< (node/expr-arity expr) 1)
        (error (format "Join was given expr ~a with arity less than 1" expr))]
       [else
        (define uppers 
          (map (lambda (arg)
                 (lift-bounds-expr arg quantvars runContext)) args))
        ; Note: assumes certain direction of associativity
        (define newTuples (joinTuple (first uppers) (second uppers)))
        (foldl (lambda (curr acc) (joinTuple acc curr)) newTuples (rest (rest uppers)))])]

    ; TRANSITIVE CLOSURE
    [(? node/expr/op/^?)
     (printf "lift-bounds ^~n")
     (buildClosureOfTupleSet (lift-bounds-expr (first args) quantvars runContext))]

    ; REFLEXIVE-TRANSITIVE CLOSURE 
    [(? node/expr/op/*?)
     (printf "lift-bounds *~n")
     (define closure (buildClosureOfTupleSet (lift-bounds-expr (first args) quantvars runContext)))
     ; We remove duplicates before we are appending 'iden
     (remove-duplicates (append closure (map (lambda (x) (list x x)) (forge:Run-atoms runContext))))]

    ; TRANSPOSE 
    [(? node/expr/op/~?)
     (printf "lift-bounds ~~~n")
     (define upper-bounds
       (map (lambda (x) (lift-bounds-expr x quantvars runContext)) args))
     ; flip the tuples in the upper bounds
     (map (lambda (x) (transposeTup x)) (first upper-bounds))]

    ; SINGLETON (typecast number to 1x1 relation with that number in it)
    [(? node/expr/op/sing?)
     (printf "lift-bounds sing~n")
     (lift-bounds-int (first args) quantvars runContext)]))

(define (lift-bounds-int expr quantvars runContext)
  (match expr
    ; constant int
    [(node/int/constant info value)
     (printf "lift-bounds int constant base case -~n")
     (define all-bounds (forge:Run-kodkod-bounds runContext)) 
     (define filtered-bounds (filter (lambda (b) (equal? "Int" (forge:relation-name (forge:bound-relation b)))) all-bounds))
     (cond [(equal? (length filtered-bounds) 1) (forge:bound-upper (first filtered-bounds))]
           [else (error (format "lift-bounds-expr on ~a: didn't have a bound for ~a in ~a" expr "Int" all-bounds))])]
    
    ; apply an operator to some integer expressions
    [(node/int/op info args)
     (printf "lift-bounds operator to some integer expression base case -~n")
     (lift-bounds-int-op expr quantvars args runContext)]
    
    ; sum "quantifier"
    ; e.g. sum p : Person | p.age  
    [(node/int/sum-quant info decls int-expr)
     (printf "lift-bounds sumQ~n")
     (define var (car (car decls)))
     (let ([quantvars (cons var quantvars)])
       (lift-bounds-expr (node/expr/constant info 1 'Int) quantvars runContext))]))

(define (lift-bounds-int-op expr quantvars args runContext)
  (match expr
    ; int addition
    [(? node/int/op/add?)
     (error "amalgam: int + not supported")]
    
    ; int subtraction
    [(? node/int/op/subtract?)
     (error "amalgam: int - not supported")]
    
    ; int multiplication
    [(? node/int/op/multiply?)
     (error "amalgam: int * not supported")]
    
    ; int division
    [(? node/int/op/divide?)
     (error "amalgam: int / not supported")]
    
    ; int sum (also used as typecasting from relation to int)
    ; e.g. {1} --> 1 or {1, 2} --> 3
    [(? node/int/op/sum?)
     (error "amalgam: int sum not supported")]
    
    ; cardinality (e.g., #Node)
    [(? node/int/op/card?)
     (printf "lift-bounds cardinality~n")
     (define all-bounds (forge:Run-kodkod-bounds runContext)) ; list of bounds objects
     (define filtered-bounds (filter (lambda (b) (equal? "Int" (forge:relation-name (forge:bound-relation b)))) all-bounds))
     (cond [(equal? (length filtered-bounds) 1) (forge:bound-upper (first filtered-bounds))]
           [else (error (format "lift-bounds-expr on ~a: didn't have a bound for ~a in ~a" expr "Int" all-bounds))])]
    
    ; remainder/modulo
    [(? node/int/op/remainder?)
     (error "amalgam: int % (modulo) not supported")]
    
    ; absolute value
    [(? node/int/op/abs?)
     (error "amalgam: int abs not supported")]
    
    ; sign-of 
    [(? node/int/op/sign?)
     (error "amalgam: int sign not supported")]))

