#lang racket

(require racket/runtime-path "log.rkt" "server-common.rkt")
(require "kks.rkt")

(provide kodkod-initializer kodkod-stderr-handler server%)

;(define-runtime-path kodkod (build-path ".." ".." ".." "bin" "kodkod"))
(define-runtime-path kodkod (build-path ".."))

(define (kodkod-initializer incremental?)
  (let* ([kodkod/jar (build-path kodkod "jar")]
         ;[kodkod/jni (build-path kodkod "jni")]
         [jars (map (curry build-path kodkod/jar)
                    (filter (curry regexp-match #rx".+\\.jar")
                            (directory-list kodkod/jar)))]
         [windows? (equal? (system-type) 'windows)]
         [java (find-executable-path (if windows? "java.exe" "java"))]
         [path-separator (if windows? ";" ":")]
         [cp (foldl string-append "" (add-between (map path->string jars) path-separator))]
         ;[lib (path->string (build-path kodkod/jni (case (system-type)
                                                     ;[(macosx) "darwin_x86_64"]
                                                     ;[(unix) "linux_x86_64"]
                                                     ;[(windows) "win_x86_64"])))]
         ;[-Djava.library.path (string-append "-Djava.library.path=" lib)]
         [error-out (build-path (find-system-path 'home-dir) "error-output.txt")])


    (if incremental?
        (subprocess #f #f #f
                    java "-Xmx2G" "-cp" cp (string-append "-Djava.library.path=" (path->string kodkod/jar))
                    "kodkod.cli.KodkodServer" "-incremental" "-error-out" error-out)
        (subprocess #f #f #f
                    java "-Xmx2G" "-cp" cp (string-append "-Djava.library.path=" (path->string kodkod/jar))
                    "kodkod.cli.KodkodServer" "-stepper" "-error-out" error-out))))

(define (kodkod-stderr-handler src err)
  (match (read-line err)
    [(pregexp #px"\\s*\\[INFO\\]\\s*(.+)" (list _ info)) (log-info [src] info) (println info)]
    [(pregexp #px"\\s*\\[WARNING\\]\\s*(.+)" (list _ warning)) (log-warning [src] warning)]
    [(pregexp #px"\\s*\\[SEVERE\\]\\s*(.+)" (list _ severe)) (log-error [src] severe)]
    [(? eof-object?) (void)]
    [line (log-debug [src] line)]))