#lang racket

(require "syntax/rules.rkt"
         "syntax/sugar.rkt"
         "syntax/syntax.rkt"
         "syntax/types.rkt"
         "core/alt-table.rkt"
         "core/bsearch.rkt"
         "core/egg-herbie.rkt"
         "core/localize.rkt"
         "core/regimes.rkt"
         "core/simplify.rkt"
         "alternative.rkt"
         "common.rkt"
         "conversions.rkt"
         "error-table.rkt"    
         "patch.rkt"
         "platform.rkt"
         "points.rkt"
         "preprocess.rkt"
         "programs.rkt"     
         "timeline.rkt"
         "sampling.rkt"
         "soundiness.rkt"
         "float.rkt")

(provide (all-defined-out))

;; I'm going to use some global state here to make the shell more
;; friendly to interact with without having to store your own global
;; state in the repl as you would normally do with debugging. This is
;; probably a bad idea, and I might change it back later. When
;; extending, make sure this never gets too complicated to fit in your
;; head at once, because then global state is going to mess you up.

(struct shellstate (table next-alts locs lowlocs patched) #:mutable)

(define (empty-shellstate)
  (shellstate #f #f #f #f #f))

(define-resetter ^shell-state^
  (λ () (empty-shellstate))
  (λ () (empty-shellstate)))

(define (^locs^ [newval 'none])
  (when (not (equal? newval 'none)) (set-shellstate-locs! (^shell-state^) newval))
  (shellstate-locs (^shell-state^)))
(define (^lowlocs^ [newval 'none])
  (when (not (equal? newval 'none)) (set-shellstate-lowlocs! (^shell-state^) newval))
  (shellstate-lowlocs (^shell-state^)))
(define (^table^ [newval 'none])
  (when (not (equal? newval 'none))  (set-shellstate-table! (^shell-state^) newval))
  (shellstate-table (^shell-state^)))
(define (^next-alts^ [newval 'none])
  (when (not (equal? newval 'none)) (set-shellstate-next-alts! (^shell-state^) newval))
  (shellstate-next-alts (^shell-state^)))
(define (^patched^ [newval 'none])
  (when (not (equal? newval 'none)) (set-shellstate-patched! (^shell-state^) newval))
  (shellstate-patched (^shell-state^)))

;; Iteration 0 alts (original alt in every repr, constant alts, etc.)
(define (starting-alts altn ctx)
  (define starting-exprs
    (reap [sow]
      (for ([conv (platform-conversions (*active-platform*))])
        (match-define (list itype) (impl-info conv 'itype))
        (when (equal? itype (context-repr ctx))
          (define otype (impl-info conv 'otype))
          (define expr* (list (get-rewrite-operator otype) (alt-expr altn)))
          (define body* (apply-repr-change-expr expr* ctx))
          (when body* (sow body*))))))
  (map make-alt starting-exprs))

;; Information
(define (list-alts)
  (printf "Key: [.] = done, [>] = chosen\n")
  (let ([ndone-alts (atab-not-done-alts (^table^))])
    (for ([alt (atab-active-alts (^table^))]
	  [n (in-naturals)])
      (printf "~a ~a ~a\n"
       (cond [(set-member? (^next-alts^) alt) ">"]
             [(set-member? ndone-alts alt) " "]
             [else "."])
       (~r #:min-width 4 n)
       (alt-expr alt))))
  (printf "Error: ~a bits\n" (errors-score (atab-min-errors (^table^)))))

;; Begin iteration
(define (choose-alt! n)
  (unless (< n (length (atab-active-alts (^table^))))
    (raise-user-error 'choose-alt! "Couldn't select the ~ath alt of ~a (not enough alts)"
                      n (length (atab-active-alts (^table^)))))
  (define picked (list-ref (atab-active-alts (^table^)) n))
  (^next-alts^ (list picked))
  (^table^ (atab-set-picked (^table^) (^next-alts^)))
  (void))

(define (score-alt alt)
  (errors-score (errors (alt-expr alt) (*pcontext*) (*context*))))

; Pareto mode alt picking
(define (choose-mult-alts altns)
  (define repr (context-repr (*context*)))
  (cond
   [(< (length altns) (*pareto-pick-limit*)) altns] ; take max
   [else
    (define best (argmin score-alt altns))
    (define altns* (sort (filter-not (curry alt-equal? best) altns) < #:key (curryr alt-cost repr)))
    (define simplest (car altns*))
    (define altns** (cdr altns*))
    (define div-size (round (/ (length altns**) (- (*pareto-pick-limit*) 1))))
    (append
      (list best simplest)
      (for/list ([i (in-range 1 (- (*pareto-pick-limit*) 1))])
        (list-ref altns** (- (* i div-size) 1))))]))

(define (choose-alts!)
  (define fresh-alts (atab-not-done-alts (^table^)))
  (define alts (choose-mult-alts fresh-alts))
  (unless (*pareto-mode*) (set! alts (take alts 1)))
  (define repr (context-repr (*context*)))
  (for ([alt (atab-active-alts (^table^))])
    (timeline-push! 'alts
                    (~a (alt-expr alt))
                    (cond
                     [(set-member? alts alt) "next"]
                     [(set-member? fresh-alts alt) "fresh"]
                     [else "done"])
                    (score-alt alt)
                    (~a (representation-name repr))))
  (^next-alts^ alts)
  (^table^ (atab-set-picked (^table^) alts))
  (void))

;; Invoke the subsystems individually
(define (localize!)
  (unless (^next-alts^)
    (raise-user-error 'localize! "No alt chosen. Run (choose-alts!) or (choose-alt! n) to choose one"))
  (timeline-event! 'localize)

  (define loc-errss
    (batch-localize-error (map alt-expr (^next-alts^)) (*context*)))
  (define repr (context-repr (*context*)))

  ; high-error locations
  (^locs^
    (for/list ([loc-errs (in-list loc-errss)]
               #:when true
               [(err expr) (in-dict loc-errs)]
               [i (in-range (*localize-expressions-limit*))])
      (timeline-push! 'locations (~a expr) (errors-score err)
                      (not (patch-table-has-expr? expr)) (~a (representation-name repr)))
      expr))

  ; low-error locations (Pherbie-only with multi-precision)
  (^lowlocs^
    (if (and (*pareto-mode*) (not (null? (platform-conversions (*active-platform*)))))
        (for/list ([loc-errs (in-list loc-errss)]
                   #:when true
                   [(err expr) (in-dict (reverse loc-errs))]
                   [i (in-range (*localize-expressions-limit*))])
          (timeline-push! 'locations (~a expr) (errors-score err) #f (~a (representation-name repr)))
          expr) 
        '()))
  
  (timeline-compact! 'mixsample)

  (void))

;; Returns the locations of `subexpr` within `expr`
(define (get-locations expr subexpr)
  (let loop ([expr expr] [loc '()])
    (match expr
      [(== subexpr)
       (list (reverse loc))]
      [(list op args ...)
       (apply
        append
        (for/list ([arg (in-list args)] [i (in-naturals 1)])
          (loop arg (cons i loc))))]
      [_
       (list)])))

;; Converts a patch to full alt with valid history
(define (reconstruct! alts)
  ;; extracts the base expression of a patch
  (define (get-starting-expr altn)
    (match (alt-event altn)
     ['(patch) (alt-expr altn)]
     [_
      (if (null? (alt-prevs altn))
          #f
          (get-starting-expr (first (alt-prevs altn))))]))

  ;; takes a patch and converts it to a full alt
  (define (reconstruct-alt altn loc0 orig)
    (let loop ([altn altn])
      (match-define (alt _ event prevs _) altn)
      (cond
       [(equal? event '(patch)) orig]
       [else
        (define event*
          ;; The 2 at the start of locs is left over from when we
          ;; differentiated between "programs" with a λ term and
          ;; "expressions" without
          (match event
           [(list 'taylor '() name var)
            (list 'taylor loc0 name var)]
           [(list 'rr '() input proof soundiness)
            (list 'rr loc0 input proof soundiness)]
           [(list 'simplify '() input proof soundiness)
            (list 'simplify loc0 input proof soundiness)]))
        (define expr* (location-do loc0 (alt-expr orig) (const (alt-expr altn))))
        (alt expr* event* (list (loop (first prevs))) (alt-preprocessing orig))])))
  
  (^patched^
   (reap [sow]
     (for ([altn (in-list alts)]) ;; does not have preproc
       (define expr0 (get-starting-expr altn))
       (if expr0     ; if expr0 is #f, altn is a full alt (probably iter 0 simplify)
           (for* ([alt0 (in-list (^next-alts^))]
                 [loc (in-list (get-locations (alt-expr alt0) expr0))])
             (sow (reconstruct-alt altn loc alt0)))
           (sow altn)))))

  (void))

;; Finish iteration
(define (finalize-iter!)
  (unless (^patched^)
    (raise-user-error 'finalize-iter! "No candidates ready for pruning!"))

  (timeline-event! 'eval)
  (define new-alts (^patched^))
  (define orig-fresh-alts (atab-not-done-alts (^table^)))
  (define orig-done-alts (set-subtract (atab-active-alts (^table^)) (atab-not-done-alts (^table^))))
  (define-values (errss costs) (atab-eval-altns (^table^) new-alts (*context*)))
  (timeline-event! 'prune)
  (^table^ (atab-add-altns (^table^) new-alts errss costs))
  (define final-fresh-alts (atab-not-done-alts (^table^)))
  (define final-done-alts (set-subtract (atab-active-alts (^table^)) (atab-not-done-alts (^table^))))

  (timeline-push! 'count
                  (+ (length new-alts) (length orig-fresh-alts) (length orig-done-alts))
                  (+ (length final-fresh-alts) (length final-done-alts)))

  (define data
    (hash 'new (list (length new-alts)
                     (length (set-intersect new-alts final-fresh-alts)))
          'fresh (list (length orig-fresh-alts)
                       (length (set-intersect orig-fresh-alts final-fresh-alts)))
          'done (list (- (length orig-done-alts) (length (or (^next-alts^) empty)))
                      (- (length (set-intersect orig-done-alts final-done-alts))
                         (length (set-intersect final-done-alts (or (^next-alts^) empty)))))
          'picked (list (length (or (^next-alts^) empty))
                        (length (set-intersect final-done-alts (or (^next-alts^) empty))))))
  (timeline-push! 'kept data)

  (define repr (context-repr (*context*)))
  (timeline-push! 'min-error (errors-score (atab-min-errors (^table^))) (format "~a" (representation-name repr)))
  (rollback-iter!)
  (void))

(define (inject-candidate! expr)
  (define new-alts (list (make-alt expr)))
  (define-values (errss costs) (atab-eval-altns (^table^) new-alts (*context*)))
  (^table^ (atab-add-altns (^table^) new-alts errss costs))
  (void))
(define (finish-iter!)
  (unless (^next-alts^) (choose-alts!))
  (unless (^locs^) (localize!))
  (reconstruct! (patch-table-run (^locs^) (^lowlocs^)))
  (finalize-iter!)
  (void))

(define (rollback-iter!)
  (^locs^ #f)
  (^lowlocs^ #f)
  (^next-alts^ #f)
  (^patched^ #f)
  (void))

(define (rollback-improve!)
  (rollback-iter!)
  (reset!)
  (^table^ #f)
  (void))

;; Run a complete iteration
(define (run-iter!)
  (when (^next-alts^)
    (raise-user-error 'run-iter! "An iteration is already in progress\n~a"
                      "Run (finish-iter!) to finish it, or (rollback-iter!) to abandon it.\n"))

  (choose-alts!)
  (localize!)
  (reconstruct! (patch-table-run (^locs^) (^lowlocs^)))
  (finalize-iter!))
  
(define (setup-context! vars specification precondition repr)
  (*context* (context vars repr (map (const repr) vars)))
  (define sample (sample-points precondition (list specification) (list (*context*))))
  (match-define (cons domain pts+exs) sample)
  (cons domain (apply mk-pcontext pts+exs)))

(define (initialize-alt-table! alternatives context pcontext)
  (match-define (cons initial simplified) alternatives)
  (*start-prog* (alt-expr initial))
  (define table (make-alt-table pcontext initial context))
  (define simplified* (append (append-map (curryr starting-alts context) simplified) simplified))
  (timeline-compact! 'mixsample)
  (timeline-event! 'eval)
  (define-values (errss costs) (atab-eval-altns table simplified* context))
  (timeline-event! 'prune)
  (^table^ (atab-add-altns table simplified* errss costs)))

;; This is only here for interactive use; normal runs use run-improve!
(define (run-improve vars prog iters
                     #:precondition [precondition #f]
                     #:preprocess [preprocess empty]
                     #:precision [precision 'binary64]
                     #:specification [specification #f])
  (rollback-improve!)
  (define repr (get-representation precision))

  (define original-points (setup-context! vars (prog->spec (or specification prog)) (prog->spec precondition) repr))
  (run-improve! iters prog specification preprocess original-points repr))

(define (run-improve! initial specification context pcontext)
  (timeline-event! 'preprocess)
  (define-values (simplified preprocessing)
    (find-preprocessing initial specification context))
  (timeline-push! 'symmetry (map ~a preprocessing))
  (define pcontext* (preprocess-pcontext context pcontext preprocessing))
  (match-define (and alternatives (cons (alt best _ _ _) _))
    (mutate! simplified context pcontext* (*num-iterations*)))
  (timeline-event! 'preprocess)
  (define final-alts
    (for/list ([altern alternatives])
      (alt-add-preprocessing altern (remove-unnecessary-preprocessing best context pcontext (alt-preprocessing altern)))))
  (values final-alts (remove-unnecessary-preprocessing best context pcontext preprocessing))) 

(define (mutate! simplified context pcontext iterations)
  (*pcontext* pcontext)
  (define expr (alt-expr (car simplified)))

  (define-values (fperrors explanations-table confusion-matrix maybe-confusion-matrix)
    (predicted-errors expr context pcontext))

  (for ([fperror (in-list fperrors)])
    (match-define (list expr truth opreds oex upreds uex) fperror)
    (timeline-push! 'fperrors
                    expr
                    truth
                    opreds
                    oex
                    upreds
                    uex))

  (for ([explanation (in-list explanations-table)])
    (match-define (list op expr expl val maybe-count flow-list) explanation)
    (timeline-push! 'explanations
                    op
                    expr
                    expl
                    val
                    maybe-count
                    flow-list))
  
  (timeline-push! 'confusion confusion-matrix)
  (timeline-push! 'maybe-confusion maybe-confusion-matrix)
  
  (initialize-alt-table! simplified context pcontext)
  (for ([iteration (in-range iterations)] #:break (atab-completed? (^table^)))
    (run-iter!))
  (extract!))

(define (extract!)
  (define ctx (*context*))
  (define repr (context-repr ctx))
  (define all-alts (atab-all-alts (^table^)))
  (*all-alts* (atab-active-alts (^table^)))
  
  (define ndone-alts (atab-not-done-alts (^table^)))
  (for ([alt (atab-active-alts (^table^))])
    (timeline-push! 'alts (~a (alt-expr alt))
                    (if (set-member? ndone-alts alt) "fresh" "done")
                    (score-alt alt) (~a (representation-name repr))))
  (define joined-alts
    (cond
     [(and (flag-set? 'reduce 'regimes) (> (length all-alts) 1)
           (equal? (representation-type repr) 'real)
           (not (null? (context-vars ctx))))
      (define opts (pareto-regimes (sort all-alts < #:key (curryr alt-cost repr)) ctx))
      (for/list ([opt (in-list opts)])
        (combine-alts opt ctx))]
     [else
      (list (argmin score-alt all-alts))]))
  (define cleaned-alts
    (cond
      [(flag-set? 'generate 'simplify)
       (timeline-event! 'simplify)

       (define input-progs (map alt-expr joined-alts))
       (define egg-query (make-egg-query input-progs (*fp-safe-simplify-rules*) #:const-folding? #f))
       (define simplified (simplify-batch egg-query))

       (for/list ([altn joined-alts] [progs simplified])
         (alt (last progs) 'final-simplify (list altn) (alt-preprocessing altn)))]
      [else
       joined-alts]))
        
  (define alts-deduplicated
    (remove-duplicates cleaned-alts alt-equal?))

  (timeline-push! 'stop (if (atab-completed? (^table^)) "done" "fuel") 1)
  ;; find the best, sort the rest by cost
  (define errss (map (λ (x) (errors (alt-expr x) (*pcontext*) (*context*))) alts-deduplicated))
  (define-values (best end-score rest)
    (for/fold ([best #f] [score #f] [rest #f])
              ([altn (in-list alts-deduplicated)] [errs (in-list errss)])
      (let ([new-score (errors-score errs)])
        (cond
         [(not best) (values altn new-score '())]
         [(< new-score score) (values altn new-score (cons best rest))] ; kick out current best
         [else (values best score (cons altn rest))]))))
  (match-define (cons best-annotated rest-annotated)
    (cond
     [(flag-set? 'generate 'proofs)
      (timeline-event! 'soundness)
      (add-soundiness (cons best rest) (*pcontext*) (*context*))]
     [else
      (cons best rest)]))
  (timeline-event! 'end)
  
  (cons best-annotated (sort rest-annotated > #:key (curryr alt-cost repr))))