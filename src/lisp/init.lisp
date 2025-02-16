(cl:in-package :cl-user)

(let ((*standard-output* (make-broadcast-stream)))
  #+sbcl (require :sb-posix))

(defpackage :ros
  (:use :cl)
  (:shadow :load :eval :package :restart :print :write)
  (:export :run :*argv* :*main* :quit :script :quicklisp :getenv :opt
           :ignore-shebang :roswell :exec :setenv :unsetenv))

(in-package :ros)
(defvar *verbose* 0)
(defvar *argv* nil)
(defvar *ros-opts* nil)
(defvar *main* nil)

;; small tools
(defun getenv (x)
  #+sbcl(sb-posix:getenv x)
  #+clisp(ext:getenv x)
  #+ccl(ccl:getenv x)
  #-(or sbcl clisp ccl) (funcall (read-from-string "asdf::getenv") x))

(defun ros-opts ()
  (or *ros-opts*
      (setf *ros-opts*
            (let((*read-eval*))
              (read-from-string (getenv "ROS_OPTS"))))))

(defun opt (param)
  (second (assoc param (ros-opts) :test 'equal)))

(or
 (ignore-errors #-asdf (require :asdf))
 (ignore-errors (cl:load (merge-pathnames "lisp/asdf3.lisp" (opt "homedir")))))

#+(and unix sbcl) ;; from swank
(progn
  (sb-alien:define-alien-routine ("execvp" %execvp) sb-alien:int
    (program sb-alien:c-string)
    (argv (* sb-alien:c-string)))

  (defun execvp (program args)
    "Replace current executable with another one."
    (let ((a-args (sb-alien:make-alien sb-alien:c-string
                                       (+ 1 (length args)))))
      (unwind-protect
           (progn
             (loop for index from 0 by 1
                and item in (append args '(nil))
                do (setf (sb-alien:deref a-args index)
                         item))
             (when (minusp
                    (%execvp program a-args))
               (let ((errno (sb-impl::get-errno)))
                 (case errno
                   (2 (error "No such file or directory: ~S" program))
                   (otherwise
                    (error "execvp(3) failed. (Code=~D)" errno))))))
        (sb-alien:free-alien a-args)))))

(defun setenv (name value)
  (declare (ignorable name value))
  #+sbcl(funcall (read-from-string "sb-posix:setenv") name value 1)
  #+ccl(ccl:setenv name value t)
  #+clisp(system::setenv name value))

(defun unsetenv (name)
  (declare (ignorable name))
  #+sbcl(funcall (read-from-string "sb-posix:unsetenv") name)
  #+ccl(ccl:unsetenv name)
  #+clisp(system::setenv name nil))

(defun quit (&optional (return-code 0) &rest rest)
  (let ((ret (or (and (numberp return-code) return-code) (first rest) 0)))
    (ignore-errors(funcall (read-from-string "asdf::quit") ret))
    #+sbcl(ignore-errors(funcall (read-from-string "cl-user::exit") :code ret))
    #+sbcl(ignore-errors(funcall (read-from-string "cl-user::quit") :unix-status ret))
    #+clisp(ext:exit ret)
    #+ccl(ccl:quit ret)))

(defun run-program (args &key output)
  (if (ignore-errors #1=(read-from-string "uiop/run-program:run-program"))
      (funcall #1# (format nil "~{~A~^ ~}" args) :output output #+(and sbcl win32) :force-shell #+(and sbcl win32) nil)
      (with-output-to-string (out)
        #+sbcl(funcall (read-from-string "sb-ext:run-program")
                       (first args) (mapcar #'princ-to-string (rest args))
                       :output out)
        #+clisp(let ((asdf:*verbose-out* out))
                 (format t "run-program:~s~%" (list (first args) :arguments (mapcar #'princ-to-string (rest args))))
                 (asdf:run-shell-command (format nil "~{~A~^ ~}" args))))))

(defun exec (args)
  #+(and unix sbcl)
  (execvp (first args) args)
  #+(and unix ccl)
  (ignore-errors
    (ccl:with-string-vector (argv args) (ccl::%execvp argv)))
  (run-program args)
  (quit -1))

(defun quicklisp (&key path (environment "QUICKLISP_HOME"))
  (unless (find :quicklisp *features*)
    (let ((path (make-pathname
                 :name "setup"
                 :type "lisp"
                 :defaults (or path
                               (and environment (getenv environment))
                               (opt "quicklisp")))))
      (when (probe-file path)
        (cl:load path)
        (let ((symbol (read-from-string "ql:*local-project-directories*")))
          (when (or (ignore-errors (probe-file path))
                    #+clisp(ext:probe-directory path))
            (set symbol (cons (merge-pathnames "local-projects/" (opt "homedir"))
                              (symbol-value symbol)))))
        t))))

#+quicklisp
(let ((path (merge-pathnames "local-projects/" (opt "homedir"))))
  (when (or (ignore-errors (probe-file path))
            #+clisp(ext:probe-directory path))
    (push path ql:*local-project-directories*)))

(defun shebang-reader (stream sub-character infix-parameter)
  (declare (ignore sub-character infix-parameter))
  (loop for x = (read-char stream nil nil)
     until (or (not x) (eq x #\newline))))

(compile 'shebang-reader)
(defun ignore-shebang ()
  (set-dispatch-macro-character #\# #\! #'shebang-reader))

(defun roswell (args &optional (output :string) trim)
  (let* ((a0 (funcall (or #+win32(lambda (x) (substitute #\\ #\/ x)) #'identity)
                      (if (zerop (length (opt "wargv0")))
                          (opt "argv0")
                          (opt "wargv0"))))
         (ret (run-program (cons a0 args) :output output)))
    (if trim
        (remove #\Newline (remove #\Return ret))
        ret)))

(let ((symbol (read-from-string "asdf::*user-cache*"))
      (impl (substitute #\- #\/ (second (assoc "impl" (ros-opts) :test 'equal)))))
  (when (boundp symbol)
    (cond ((listp (symbol-value symbol))
           (set symbol (append (symbol-value symbol) (list impl))))
          ((pathnamep (symbol-value symbol))
           (set symbol (merge-pathnames (format nil "~A/" impl) (symbol-value symbol))))
          (t (cl:print "tbd.....")))))

(defun source-registry (cmd arg &rest rest)
  (declare (ignorable cmd rest))
  (let ((dir (format nil "~{~A~^:~}"
                     (loop for i = arg then (subseq i (1+ pos))
                        for pos = (position #\: i)
                        for part = (if pos (subseq i 0 pos) i)
                        when (and (not (zerop (length part)))
                                  (probe-file part))
                        collect (namestring (probe-file part))
                        while pos))))
    (if (zerop (length dir))
        (warn "Source-registry ~S is invalid. Ignored." arg)
        (funcall (read-from-string "asdf:initialize-source-registry") dir))))

(defun system (cmd args &rest rest)
  (declare (ignorable cmd rest))
  (loop for ar = args then (subseq ar (1+ p))
     for p = (position #\, ar)
     for arg = (if p (subseq ar 0 p) ar)
     do (if (find :quicklisp *features*)
            (funcall (read-from-string "ql:quickload") arg :silent t)
            (asdf:operate 'asdf:load-op arg))
     while p))

(setf (fdefinition 'load-system)
      #'system)

(defun package (cmd arg &rest rest)
  (declare (ignorable cmd rest))
  (setq *package* (find-package (read-from-string (format nil "#:~A" arg)))))

(defun system-package (cmd arg &rest rest)
  (declare (ignorable cmd rest))
  (apply #'system cmd arg rest)
  (apply #'package cmd arg rest))

(defun eval (cmd arg &rest rest)
  (declare (ignorable cmd rest))
  (cl:eval (read-from-string arg)))

(defun restart (cmd arg &rest rest)
  (declare (ignorable cmd rest))
  (funcall (read-from-string arg)))

(defun entry (cmd arg &rest rest)
  (declare (ignorable cmd rest))
  (apply (read-from-string arg) *argv*))

(setf (fdefinition 'init) #'eval)

(defun print (cmd arg &rest rest)
  (declare (ignorable cmd rest))
  (cl:print (cl:eval (read-from-string arg))))

(defun write (cmd arg &rest rest)
  (declare (ignorable cmd rest))
  (cl:write (cl:eval (read-from-string arg))))

(defun script (cmd arg &rest rest)
  (declare (ignorable cmd))
  (setf *argv* rest)
  (if (probe-file arg)
      (with-open-file (in arg)
        (let ((line(read-line in)))
          (push :ros.script *features*)
          (funcall #+(or sbcl clisp) 'cl:load
                   #-(or sbcl clisp) 'asdf::eval-input
                   (make-concatenated-stream
                    (make-string-input-stream
                     (format nil "(cl:setf cl:*load-pathname* ~S cl:*load-truename* (truename cl:*load-pathname*))~A" (merge-pathnames (make-pathname :defaults arg))
                             (if (equal (subseq line 0 (min (length line) 2)) "#!")
                                 "" line)))
                    in
                    (make-string-input-stream
                     (if (eql cmd :script)
                         "(cl:apply 'main ros:*argv*)"
                         "(setf ros:*main* 'main)"))))
          (setf *features* (remove :ros.script *features*))))
      (format t "script ~S does not exist~%" arg)))

(defun load (x file)
  (declare (ignore x))
  (cl:load file))

(defun run (list)
  (loop :for elt :in list
     :do (apply (intern (string (first elt)) (find-package :ros)) elt)))

(push :ros.init *features*)

#+clisp
(loop
   with *package* = (find-package :cl-user)
   for i in ext:*args*
   do (cl:eval (cl:read-from-string i)))
