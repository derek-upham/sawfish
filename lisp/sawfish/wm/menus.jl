;; menus.jl -- popup menus

;; Copyright (C) 1999 John Harper <john@dcs.warwick.ac.uk>

;; This file is part of sawfish.

;; sawfish is free software; you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; sawfish is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with sawfish; see the file COPYING.  If not, write to
;; the Free Software Foundation, 51 Franklin Street, Fifth Floor, 
;; Boston, MA 02110-1301 USA.

(define-structure sawfish.wm.menus

    (export menu-start-process
	    menu-stop-process
	    popup-menu
	    popup-window-ops-menu
	    popup-window-list-menu
	    popup-root-menu
	    popup-apps-menu
	    add-window-menu-toggle
	    add-poweroff-menu)

    (open rep
	  rep.regexp
	  rep.io.files
	  rep.io.processes
	  rep.data.tables
          rep.system
	  sawfish.wm.events
	  sawfish.wm.windows
	  sawfish.wm.misc
	  sawfish.wm.custom
	  sawfish.wm.frames
	  sawfish.wm.commands
	  sawfish.wm.util.groups
	  sawfish.wm.workspace
	  sawfish.wm.state.maximize
	  sawfish.wm.state.iconify
	  sawfish.wm.commands.launcher
	  sawfish.wm.ext.error-handler)

  (define-structure-alias menus sawfish.wm.menus)

  ;; Suppress annoying compiler warnings
  (eval-when-compile (require 'rep.io.timers))

  (defcustom menus-include-shortcuts nil
    "Display key-binding information in menu items."
    :group misc
    :type boolean)

  (defvar menu-program (expand-file-name "sawfish-menu" sawfish-exec-directory)
    "Location of the program implementing sawfish's menu interface.")

  ;; rep provides make-temp-file, but that mechanism has problems for us:
  ;;
  ;; - The public "/tmp" directory invites security risks.
  ;; - We get a random file each time, so we have to worry about cleanups.
  ;;
  ;; Since we don't have to worry about multiple menus running at the
  ;; same time, we can re-use the same menu file over and over again.
  ;;
  ;; https://en.wikipedia.org/wiki/TMPDIR indicates that TMPDIR is part
  ;; of the Single UNIX Specification.  It allows for a private,
  ;; strongly owned directory, reducing security concerns.
  (defvar menu-program-xml-file (expand-file-name "sawfish-popup-menu.xml" (getenv "TMPDIR")))

  ;; The GTK4 menu generator presents one XML menu, and then exits,
  ;; so this false value reflects that behavior.
  (defvar menu-program-stays-running nil
    "When non-nil, the menu program is never stopped. If a number, then this
is taken as the number of seconds to let the process hang around unused
before killing it.")

  ;; the active user interface process
  (define menu-process nil)

  ;; output from the user-interface process that's received but not
  ;; yet processed
  (define menu-pending nil)

  ;; non-nil when we're waiting for a response from the ui process
  ;; if a window, then it's the window that received the event causing
  ;; the menu to be shown
  (define menu-active nil)

  ;; hash table mapping nicknames to result objects without read syntax
  (define nickname-table)
  (define nickname-index)

  ;; if menu-program-stays-running is a number, this may be a timer
  ;; waiting to kill the process
  (define menu-timer nil)

  (defvar window-ops-menu
    ;; Mysterious underscore "_" before a string offers (human
    ;; langugage) translation. The one inside of a string is
    ;; a shortcut key.
    `((,(_ "Mi_nimize") iconify-window
       (insensitive . ,(lambda (w)
                         (not (or (window-iconifiable-p w)
				  (not (window-get w 'never-iconify)))))))
      (,(lambda (w)
          (if (window-maximized-p w)
              (_ "Unma_ximize")
            (_ "Ma_ximize"))) maximize-window-toggle
            (insensitive . ,(lambda (w)
                              (not (or (window-maximized-p w)
                                       (window-maximizable-p w)
				       (not (window-get w 'never-maximize)))))))
      (,(_ "_Move") move-window-interactively
       (insensitive . ,(lambda (w)
			 (window-get w 'fixed-position))))
      (,(_ "_Resize") resize-window-interactively
       (insensitive . ,(lambda (w)
			 (window-get w 'fixed-size))))
      (,(_ "_Resize to") resize-window-prompt
       (insensitive . ,(lambda (w)
			 (window-get w 'fixed-size))))
      (,(_ "_Close") delete-window
       (insensitive . ,(lambda (w)
			 (window-get w 'never-delete))))
      ()
      (,(_ "_Toggle") . window-ops-toggle-menu)
      (,(_ "In _group") . window-group-menu)
      (,(_ "_Workspace")
       (,(_ "Move to _Previous workspace") send-to-previous-workspace)
       (,(_ "Move to _Next workspace") send-to-next-workspace)
       ()
       (,(_ "Copy to P_revious workspace") copy-to-previous-workspace)
       (,(_ "Copy to Ne_xt workspace") copy-to-next-workspace))
      (,(_ "_Grow & Pack")
       (,(_ "Grow left") grow-window-left)
       (,(_ "Grow right") grow-window-right)
       (,(_ "Grow up") grow-window-up)
       (,(_ "Grow down") grow-window-down)
       ()
       (,(_ "Pack left") pack-window-left)
       (,(_ "Pack right") pack-window-right)
       (,(_ "Pack up") pack-window-up)
       (,(_ "Pack down") pack-window-down))
      (,(_ "Shrink & _Yank")
       (,(_ "Shrink left") shrink-window-left)
       (,(_ "Shrink right") shrink-window-right)
       (,(_ "Shrink up") shrink-window-up)
       (,(_ "Shrink down") shrink-window-down)
       ()
       (,(_ "Yank left") yank-window-left)
       (,(_ "Yank right") yank-window-right)
       (,(_ "Yank up") yank-window-up)
       (,(_ "Yank down") yank-window-down))
      (,(_ "Stac_king")
       (,(_ "_Raise") raise-window)
       (,(_ "_Lower") lower-window)
       ()
       (,(_ "_Upper layer") raise-window-depth)
       (,(_ "Lo_wer layer") lower-window-depth))
      (,(_ "Frame ty_pe") . frame-type-menu)
      (,(_ "Frame sty_le") . frame-style-menu)))

  (defvar window-ops-toggle-menu '())

  ;; Window list menu
  (defvar window-menu nil)

  (defvar root-menu
    ;; Mysterious underscore "_" before a stringoffers (human
    ;; langugage) translation. The one inside of a string
    ;; specifies shortcut key.
    `((,(_ "Sawfish Rootmenu") nil (insensitive . t))
      ()
      (,(_ "_Windows") . window-menu)
      (,(_ "Work_spaces") . workspace-menu)
      ()
      (,(_ "_Programs") . apps-menu)
      ()
      (,(_ "Sessi_on")
       (,(_ "Display _Errors") display-errors)
       (,(_ "_Reload Appsmenu") update-apps-menu)
       ()
       (,(_ "Restart _Sawfish") restart)
       (,(_ "_Quit Sawfish") quit))
      ()
      (,(_ "_Help")
       (,(_ "Sawfish _FAQ") help:show-faq)
       (,(_ "Sawfish _News") help:show-news)
       (,(_ "Sawfish _Wiki") help:show-homepage)
       (,(_ "Sawfish _Manual") help:show-programmer-manual)
       ()
       (,(_ "_About Sawfish") help:about))))

  (defvar apps-menu)

  (define (add-poweroff-menu)
    "Add poweroff related menu items to Session sub-menu."
    (user-require 'sawfish.wm.commands.poweroff)
    (let ((menu (assoc (_ "Sessi_on") root-menu)))
      (when menu
	(nconc menu `(()
		      (,(_ "_Lockdown Display")
		       (poweroff 'lockdown))
		      (,(_ "L_ogout from Session")
		       (poweroff 'logout))
		      ()
		      (,(_ "_Reboot System")
		       (poweroff 'reboot))
		      (,(_ "_Shutdown System")
		       (poweroff 'halt))
		      (,(_ "S_uspend System")
		       (poweroff 'suspend))
		      (,(_ "_Hibernate System")
		       (poweroff 'hibernate)))))))

  (define (menu-start-process menu-program-args)
    (when menu-timer
      (delete-timer menu-timer)
      (setq menu-timer nil))
    (unless (and menu-process (process-in-use-p menu-process))
      (when menu-process
	(kill-process menu-process)
	(setq menu-process nil))
      (let ((menu-sentinel (lambda ()
                             (menu-unlock)
			     (when (and menu-process
					(not (process-in-use-p menu-process)))
			       (setq menu-process nil))
			     (when menu-timer
			       (delete-timer menu-timer)
			       (setq menu-timer nil))))
	    (menu-filter (lambda (output)
			   (setq output (concat menu-pending output))
			   (setq menu-pending nil)
			   (condition-case nil
			       (let
				   ((result (read-from-string output)))
				 ;; GTK takes the focus for its menu,
				 ;; but later returns it to the original
				 ;; window. We want the focus to be
				 ;; restored by the time the menu-chosen
				 ;; command is invoked..
				 (accept-x-input)
				 (menu-dispatch result))
			     (end-of-stream
			      (setq menu-pending output))))))
	(setq menu-process (make-process menu-filter menu-sentinel)))
      (set-process-error-stream menu-process nil)
      (or (apply start-process menu-process menu-program menu-program-args)
	  (error "Can't start menu backend: %s" menu-program))))

  (define (menu-stop-process #!optional force)
    (when menu-process
      (cond ((and (not force) (numberp menu-program-stays-running))
	     ;; number of seconds to let it hang around for
	     (require 'rep.io.timers)
	     (setq menu-timer (make-timer (lambda ()
					    (when menu-process
					      (kill-process menu-process)
					      (setq menu-process nil))
					    (setq menu-timer nil))
					  menu-program-stays-running)))
	    ((or force (not menu-program-stays-running))
	     (kill-process menu-process)
	     (setq menu-process nil)))))

  (define (make-nickname obj)
    (let ((nick nickname-index))
      (setq nickname-index (1+ nickname-index))
      (table-set nickname-table nick obj)
      nick))

  (define (nicknamep arg) (fixnump arg))
  (define (nickname-ref nick) (table-ref nickname-table nick))

  ;; Currently only use is to pass the window object.
  (define menu-args (make-fluid '()))
  (define where-is-fun (make-fluid '()))

  ;; map radio-group ids to the last widget
  (define group-table (make-fluid))
  ;; utilities for group-table
  (define (make-group-table) (make-table symbol-hash eq))
  (define (group-id-set id w) (table-set (fluid group-table) id w))
  (define (group-id-ref id) (table-ref (fluid group-table) id))

  (define (round-trip-safe-action action)
    (cond
     ;; In a Rep context, we know that symbol 'nil' isn't an action,
     ;; even though it looks like it could be one.  Replace it with
     ;; the nil value.
     ((eq action 'nil) nil)
     ;; We can pass through normal symbols.
     ((symbolp action) action)
     ;; Convert everything else to a number, to reference later.
     (t (make-nickname action))))

  ;; menu-expander takes a menu definition, such as `root-menu', and
  ;; evaluates the dynamic portions to produce a final, static
  ;; representation, still within the menu definition format.
  (define (menu-expander cell)
    ;; cell may have empty list structure (), in which case pass through unchanged.
    (if cell
        ;; All cells have a label, the first element.
        (let ((label (car cell)))
	  (when (functionp label)
	    (setq label (apply label (fluid menu-args))))
          ;; Now we drop the first element.  But it might have been a
          ;; cons pair!  If what is left is a variable, evaluate it and
          ;; substitute it.  If we then have a function, evaluate that
          ;; and substitute it.
          (setq cell (cdr cell))
          (when (and (symbolp cell) (not (null cell)))
            (setq cell (symbol-value cell)))
          (when (functionp cell)
            (setq cell (apply cell (fluid menu-args))))

	  (when cell
            ;; Submenus are a list, where the first element of the list
            ;; is an initial label.
	    (if (and (consp (car cell)) (stringp (car (car cell))))
	        ;; recurse through sub-menu
	        (setq cell (mapcar menu-expander cell))
              ;; Leaf menu items have an action, followed by an alist of
              ;; options.
	      (let* ((action (car cell))
		     (options (cdr cell))
		     (shortcut (and (fluid where-is-fun)
				    (symbolp action)
				    ((fluid where-is-fun) action))))
                (setq action (round-trip-safe-action action))
	        ;; scan the alist of options
	        (setq options (mapcar (lambda (opt)
			                (if (functionp (cdr opt))
				            (cons (car opt)
					          (apply (cdr opt)
						         (fluid menu-args)))
				          opt))
                                      options))
	        (when shortcut
                  (setq label (format nil "%s (%s)" label shortcut)))
	        (setq cell (cons action options)))))
	  (cons label cell))
      '()))

  ;; Take an expanded, static menu definition, and provide a GTK4 menu
  ;; definition for it in SXML.
  ;;
  ;; Note that this function handes top-level menus and submenus.  The
  ;; necessary context comes from the caller:
  ;;
  ;; - The element-prefix is an SXML element-name and attribute list, and we
  ;;   embed the menu entries into that element.
  ;; - The menu-label is the visible name (string) of the parent, e.g.,
  ;;   a "File" menu-label for entries "New" and "Open" and "Save".
  ;;
  ;; We provide special values for these when creating a top-level menu.
  (define (menu-gtk4-format element-prefix menu-label entries)
    (define (entry-separator? e) (null e))
    (define (entry-label e) (car e))
    (define (entry-actuation e) (cadr e))
    (define (entry-properties e) (cddr e))
    (define (entry-submenu? e) (and (consp (entry-actuation e)) (not (null (entry-actuation e)))))
    (define (entry-submenu-entries e) (cdr e))
    (define (entry-label-only? e) (null (entry-actuation e)))
    (define (entry-group e) (cdr (assq 'group (entry-properties e))))
    (define (entry-has-checkbox? e) (assq 'check (entry-properties e)))
    (define (entry-checked? e) (cdr (assq 'check (entry-properties e))))
    (define (entry-insensitive? e) (cdr (assq 'insensitive (entry-properties e))))
    (define (id->string x) (cond ((numberp x) (number->string x))
                                 ((symbolp x) (symbol-name x))
                                 (t (format nil "?%S?" x))))

    (define (entry->item e)
      (cond ((and (entry-group e) (entry-checked? e))
             `(item ()
                    (attribute ((name . "label")) ,(entry-label e))
                    (attribute ((name . "action")) ,(concat "app." (id->string (entry-group e))))
                    (attribute ((name . "target")) ,(id->string (entry-actuation e)))
                    (attribute ((name . "checked")) "true")))
            ((entry-group e)
             `(item ()
                    (attribute ((name . "label")) ,(entry-label e))
                    (attribute ((name . "action")) ,(concat "app." (id->string (entry-group e))))
                    (attribute ((name . "target")) ,(id->string (entry-actuation e)))))
            ((entry-checked? e)
             `(item ()
                    (attribute ((name . "label")) ,(entry-label e))
                    (attribute ((name . "action")) ,(concat "app." (id->string (entry-actuation e))))
                    (attribute ((name . "checked")) "true")))
            ((and (entry-has-checkbox? e))
             `(item ()
                    (attribute ((name . "label")) ,(entry-label e))
                    (attribute ((name . "action")) ,(concat "app." (id->string (entry-actuation e))))
                    (attribute ((name . "checked")) "false")))
            ;; The only label-only entry that I know of is the rootmenu label,
            ;; which is also insensitive.  But let's catch any strays.  The menu
            ;; generator utility goes into more detail about this special action.
            ((or (entry-insensitive? e) (entry-label-only? e))
             `(item ()
                    (attribute ((name . "label")) ,(entry-label e))
                    (attribute ((name . "action")) ,(concat "insensitive.none"))))
            (t
             `(item ()
                    (attribute ((name . "label")) ,(entry-label e))
                    (attribute ((name . "action")) ,(concat "app." (id->string (entry-actuation e))))
                    ))))

    ;; state machine:
    ;;
    ;; Accumulate menu entries until EOL or a () separator.
    ;; Either of them causes us to flush the accumulated entries in a
    ;; new <section> element, which we accumulate for final return.
    ;;
    ;; Any submenu (an entry with a non-empty list action) triggers a recursive call.
    (let loop ((sections nil)
               (section-entries nil)
               (entries entries))
      (define (flush-section-entries!)
        (when section-entries ; handle stray duplicate separators by ignoring them
          (setq sections (cons `(section () ,@(nreverse section-entries)) sections))))
      (if (null entries)
          ;; terminate
          (progn
            (flush-section-entries!)
            (append element-prefix
                    (if menu-label `((attribute ((name . "label")) ,menu-label)) '())
                    (nreverse sections))) ; and exit
        (let ((entry (car entries))
              (remaining (cdr entries)))
          (cond ((entry-separator? entry)
                 (flush-section-entries!)
                 (loop sections nil remaining))
                ((entry-submenu? entry)
                 (setq section-entries (cons (menu-gtk4-format `(submenu ())
                                                               (entry-label entry)
                                                               (entry-submenu-entries entry))
                                             section-entries))
                 (loop sections section-entries remaining))
                (t
                 (setq section-entries (cons (entry->item entry) section-entries))
                 (loop sections section-entries remaining)))))))

  ;; menu-emit produces a GTK4 menu definition in SXML format, along
  ;; with setting up the nickname information.
  (define (menu-emit spec)
    (let-fluids ((group-table (make-group-table))
                 (where-is-fun (and menus-include-shortcuts
				    (require 'sawfish.wm.util.keymap)
				    (make-memoizing-where-is
				     (list global-keymap window-keymap)))))
      (setq nickname-table (make-table eq-hash eq))
      (setq nickname-index 0)
      (let* ((evaluated-menu (mapcar menu-expander spec))
             (converted-menu (menu-gtk4-format '(menu ((id . "menu"))) nil evaluated-menu)))
        `(interface () ,converted-menu))))

  (define (menu-unlock)
    (setq menu-active nil)
    (frame-draw-mutex nil))

  (define (menu-dispatch result)
    (let ((orig-win menu-active))
      (menu-stop-process)
      (when (nicknamep result)
	(setq result (nickname-ref result)))
      (menu-unlock)
      (setq nickname-table nil)
      (when result
	(when (windowp orig-win)
	  (current-event-window orig-win))
	(cond ((commandp result)
	       (call-command result))
	      ;; This supports (define (func) (interactive) ...)
	      ((functionp result)
	       (result))
	      ((consp result)
	       (user-eval result))
	      (t result)))))

  (define (popup-menu spec)
    (or spec (error "No menu given to popup-menu"))
    (if (and menu-active menu-process (process-in-use-p menu-process))
	(error "Menu already active")
      (progn
	(setq menu-active (or (current-event-window) (input-focus)))
	(condition-case error-data
	    (progn
	      ;; prevent any depressed button being redrawn until the menu
	      ;; is popped down
	      ;; XXX expose events screw this up..
	      (when (clicked-frame-part)
		(frame-draw-mutex t))
	      ;; This function is probably called from a ButtonPress event,
	      ;; so cancel the implicit pointer grab (to allow the menu's grab
	      ;; to succeed)
	      (ungrab-pointer)
	      (ungrab-keyboard)
	      (sync-server t)
	      (when (functionp spec)
		(setq spec (spec)))
              ;; GtkBuilder can parse XML from a file, or from a string.
              ;; Our lower-level utility supports reading from stdin
              ;; into a string, to pass to GtkBuilder.  But this depends
              ;; on sending EOF to the utilty, to tell us when the
              ;; string ends.
              ;;
              ;; rep's process layer doesn't expose the concept of
              ;; closing the rep-to-process stream.  It only happens
              ;; implicitly when shutting down the process.
              ;;
              ;; We could fix this by adding the feature to rep, but
              ;; right now we work around it.  Write the XML menu to a
              ;; temporary file, and point the utility to the temporary
              ;; file.
              (call-with-output-file menu-program-xml-file
                                     (lambda (ostream)
                                       (xml-fragments-emit ostream
                                                           (sxml->xml-fragments
                                                            (menu-emit spec)))))
	      (menu-start-process (list menu-program-xml-file)))
          (error
           ;; prevents spurious errors with subsequent menus
           (setq menu-active nil)
           (apply signal error-data))))))

  (define (popup-window-ops-menu w)
    "Display the menu listing all window operations."
    (let-fluids ((menu-args (list w)))
      (popup-menu window-ops-menu)))

  (define (popup-window-list-menu)
    "Display the window-list menu."
    (popup-menu window-menu))

  (define (popup-root-menu)
    "Display the main menu."
    (popup-menu root-menu))

  (define (popup-apps-menu)
    "Display the applications menu."
    (popup-menu apps-menu))

  ;;###autoload
  (define-command 'popup-window-ops-menu popup-window-ops-menu #:spec "%W")
  (define-command 'popup-root-menu popup-root-menu)
  (define-command 'popup-apps-menu popup-apps-menu)
  (define-command 'popup-window-list-menu popup-window-list-menu)

;;; menu modifiers

  (define (add-window-menu-toggle label command #!optional predicate)
    (let ((item (list* label command
		       (and predicate (list (cons 'check predicate))))))
      (let loop ((rest window-ops-toggle-menu))
	(cond
	 ((null rest)
	  (setq window-ops-toggle-menu (nconc window-ops-toggle-menu
					      (list item))))
	 ((eq (cadar rest) command)
	  (rplaca rest item))
	 (t (loop (cdr rest)))))))

  ;;;;


  (define (sxml->xml-string sexp)
    (let ((ostream (make-string-output-stream)))
      (xml-fragments-emit ostream (sxml->xml-fragments sexp))
      (get-output-stream-string ostream)))

  (define (xml-fragments-emit ostream xml-fragments)
    (tree-fold (lambda (os x) (write os x) os) ostream xml-fragments))

  (define (sxml->xml-fragments sexp)
    (cond ((stringp sexp) (sxml-text->xml-fragments sexp))
          (t (sxml-element->xml-fragments sexp))))

  (define (sxml-element->xml-fragments sexp)
    (let ((element-name (car sexp))
          (attributes (cadr sexp))
          (children (cddr sexp)))
      (unless (symbolp element-name)
        (error "element-name not symbol"))
      (unless (and (proper-list? attributes)
                   (every? sxml-attribute-pair? attributes))
        (error "attributes not list"))
      (let ((attribute-fragments (mapcar sxml-attribute->xml-fragments attributes)))
        `(,(format nil "\n<%s" element-name)
          ,(if attribute-fragments " " "")
          ,attribute-fragments
          ">"
          ,(mapcar sxml->xml-fragments children)
          ,(format nil "</%s>\n" element-name)))))

  (define (sxml-attribute->xml-fragments kv-pair)
    (let ((key (car kv-pair))
          (value (cdr kv-pair)))
      (format nil "%s='%s'" key (xml-quote value))))

  (define (sxml-text->xml-fragments text)
    (xml-quote text))

  (define (sxml-attribute-pair? x)
    (and (consp x) (symbolp (car x)) (stringp (cdr x))))

  ;; expand-last-match is broken; it substitutes the bare ampersand for
  ;; the matched character, and we have to backslash-escape it to get
  ;; the ampersand character.
  (define (xml-quote str)
    (string-replace "'"
                    "\\&apos;"
                    (string-replace ">"
                                    "\\&gt;"
                                    (string-replace "<"
                                                    "\\&lt;"
                                                    (string-replace "&"
                                                                    "\\&amp;"
                                                                    str)))))

  (define (every? pred lst)
    (cond ((null lst) t)
          (t
           (and (pred (car lst)) (every? pred (cdr lst))))))

  (define (proper-list? lst)
    (or (null lst)
        (and (consp lst) (proper-list? (cdr lst)))))

  (define (tree-fold op accum tree)
    (cond ((null tree) accum)
          ((consp tree) (tree-fold op (tree-fold op accum (car tree)) (cdr tree)))
          (t (op accum tree))))

  (define (call-with-output-file filename func)
    (let ((ofile nil))
      (unwind-protect
          (progn
            (setq ofile (open-file filename 'write))
            (func ofile))
        (when ofile
          (flush-file ofile)
          (close-file ofile)))))
  )

