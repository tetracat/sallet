;;; sallet.el --- Select candidates in a buffer. -*- lexical-binding: t -*-

;; Copyright (C) 2014-2015 Matúš Goljer <matus.goljer@gmail.com>

;; Author: Matúš Goljer <matus.goljer@gmail.com>
;; Maintainer: Matúš Goljer <matus.goljer@gmail.com>
;; Version: 0.0.1
;; Created: 31st December 2014
;; Package-requires: ((dash "2.10.0"))
;; Keywords: convenience

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License
;; as published by the Free Software Foundation; either version 3
;; of the License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program. If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;;; Code:
(require 'dash)
(require 'flx)

(defun sallet-matcher-default (candidates prompt)
  (let ((i 0)
        (re nil)
        (parts (split-string prompt)))
    (mapc
     (lambda (c)
       (let ((c-str (if (stringp c) c (car c))))
         (when (--all? (string-match-p (regexp-quote it) c-str) parts)
           (push i re)))
       (setq i (1+ i)))
     candidates)
    (nreverse re)))

(defun sallet-matcher-flx (candidates prompt)
  (let ((i 0)
        (re nil)
        (parts (split-string prompt)))
    ;; first fuzzy score/filter by first input
    ;; TODO: add a function modifier that would transform any function into "first item matcher"
    (mapc
     (lambda (c)
       (let ((c-str (if (stringp c) c (car c))))
         (-when-let (score (flx-score c-str (car parts)))
           (push (cons i score) re)))
       (setq i (1+ i)))
     candidates)
    ;; sort by score
    (sort re (lambda (a b) (< (cadr a) (cadr b))))
    (--map (car it) re)))

;; TODO: use eieio to represent the sources?
;; TODO: pass state instead of prompt everywhere
(defvar sallet-source-default
  '(;; function matching and ranking/sorting candidates
    (matcher . sallet-matcher-default)
    ;; rendered, is passed a candidate and the prompt
    (renderer . (lambda (candidate prompt) candidate))
    ;; a function generating candidates, a list or vector of candidates
    (candidates . nil)
    ;; function generating candidates, takes prompt, returns a vector
    (generator . nil)
    (header . "Select a candidate")
    ;; action: TODO: (cons action-name action-function)
    ;; TODO: pridat akciu ktora nevypne rozhranie
    (action . identity)))

(defvar sallet-source-buffer
  '((candidates . helm-buffer-list)
    (matcher . sallet-matcher-flx)
    (action . switch-to-buffer)
    ;; (action . (lambda (c) (message "%S" c)))
    (header . "Buffers")))

(defvar sallet-source-bookmarks-file-only
  '((candidates . bmkp-file-alist-only)
    (matcher . sallet-matcher-default)
    (renderer . (lambda (c _) (car c)))
    (action . (lambda (bookmark-name)
                (bmkp-jump-1 (cons "" bookmark-name) 'switch-to-buffer nil)))
    (header . "Bookmarks")))

(defvar sallet-source-occur
  '((candidates . nil)
    (matcher . nil)
    (renderer . (lambda (c _) (car c)))
    (action . (lambda (c)
                ;; TODO: preco nestaci goto-char? Asi treba nejak
                ;; recovernut "selected-window" v action handlery
                (set-window-point (selected-window) (cdr c))))))

(defun sallet-source-get-matcher (source)
  (cdr (assq 'matcher source)))
(defun sallet-source-get-renderer (source)
  (cdr (assq 'renderer source)))
(defun sallet-source-get-candidates (source)
  (cdr (assq 'candidates source)))
(defun sallet-source-get-generator (source)
  (cdr (assq 'generator source)))
(defun sallet-source-get-header (source)
  (cdr (assq 'header source)))
(defun sallet-source-get-action (source)
  (cdr (assq 'action source)))
(defun sallet-source-get-processed-candidates (source)
  (cdr (assq 'processed-candidates source)))

(defun sallet-source-set-candidates (source candidates)
  (setf (cdr (assq 'candidates source)) candidates))
(defun sallet-source-set-processed-candidates (source processed-candidates)
  (setf (cdr (assq 'processed-candidates source)) processed-candidates))

(defun sallet-source-get-candidate (source n)
  (elt (sallet-source-get-candidates source) n))

;; TODO: get rid of default options, or require explicit inheritance?
;; ... because setting something to `nil' won't disable it but force
;; inheritance now
(defun sallet-init-source (source)
  "Initiate the source."
  (let ((cs nil))
    ;; candidates
    (let ((candidates (sallet-source-get-candidates source)))
      (cond
       ((functionp candidates)
        (setq candidates (funcall (sallet-source-get-candidates source))))
       ((or (listp candidates)
            (vectorp candidates)))
       ((functionp (sallet-source-get-generator source))
        (setq candidates nil))
       (t (error "Invalid source: no way to generate candidates")))
      (when (and candidates
                 (not (vectorp candidates)))
        (setq candidates (vconcat candidates)))
      (push `(candidates . ,candidates) cs))
    ;; generator
    (-when-let (generator (sallet-source-get-generator source))
      (push `(generator . ,generator) cs))
    ;; matcher
    ;; (-if-let (matcher (sallet-source-get-matcher source))
    ;;     (push `(matcher . ,matcher) cs)
    ;;   (push `(matcher . ,(sallet-source-get-matcher sallet-source-default)) cs))
    (push `(matcher . ,(sallet-source-get-matcher source)) cs)
    ;; renderer
    (-if-let (renderer (sallet-source-get-renderer source))
        (push `(renderer . ,renderer) cs)
      (push `(renderer . ,(sallet-source-get-renderer sallet-source-default)) cs))
    ;; action
    (-if-let (action (sallet-source-get-action source))
        (push `(action . ,action) cs)
      (push `(action . ,(sallet-source-get-action sallet-source-default)) cs))
    ;; header
    (-if-let (header (sallet-source-get-header source))
        (push `(header . ,header) cs)
      (push `(header . ,(sallet-source-get-header sallet-source-default)) cs))
    (push `(processed-candidates . ,(number-sequence 0 (1- (length (sallet-source-get-candidates cs))))) cs)
    cs))

(defvar sallet-state nil
  "Current state.

SOURCES is a list of initialized sources.

CURRENT-BUFFER is the buffer from which sallet was executed.

PROMPT is the current prompt.

SELECTED-CANDIDATE is the currently selected candidate.")

(defun sallet-state-get-sources (state)
  (cdr (assoc 'sources state)))
(defun sallet-state-get-current-buffer (state)
  (cdr (assoc 'current-buffer state)))
(defun sallet-state-get-prompt (state)
  (cdr (assoc 'prompt state)))
(defun sallet-state-get-selected-candidate (state)
  (cdr (assoc 'selected-candidate state)))
(defun sallet-state-get-candidate-buffer (state)
  (cdr (assoc 'candidate-buffer state)))

(defun sallet-state-set-prompt (state prompt)
  (setf (cdr (assoc 'prompt state)) prompt))
(defun sallet-state-set-selected-candidate (state selected-candidate)
  (setf (cdr (assoc 'selected-candidate state)) selected-candidate))

(defun sallet-state-incf-selected-candidate (state)
  (incf (cdr (assoc 'selected-candidate state))))
(defun sallet-state-decf-selected-candidate (state)
  (decf (cdr (assoc 'selected-candidate state))))

(defun sallet-state-get-number-of-all-candidates (state)
  (-sum (--map (length (or (sallet-source-get-processed-candidates it)
                           (sallet-source-get-candidates it)))
               (sallet-state-get-sources state))))

;; TODO: make this function better, it's a mess
(defun sallet-state-get-selected-source (state)
  (let* ((offset (sallet-state-get-selected-candidate state))
         (sources (sallet-state-get-sources state))
         (re (car sources))
         (total 0)
         (total-old total))
    (--each-while sources (< total offset)
      (setq total-old total)
      ;; TODO: abstract the `or' here... we just want to get some
      ;; candidates.  Search for it everywhere, it is used all over
      ;; the source
      ;; TODO: there's a bug when the matcher returns no processed
      ;; candiadates => it shows all of them.  We need to determine if
      ;; we filtered out everything or no matcher is present---maybe
      ;; the generator should also simply generate the processed
      ;; list... or make a "super-default" matcher that always matches
      ;; everything by returning just the proper number-sequence.
      (setq total (+ total (length (or (sallet-source-get-processed-candidates it)
                                       (sallet-source-get-candidates it)))))
      (setq re it))
    (cons re (sallet-source-get-candidate
              re
              (-if-let (proc (sallet-source-get-processed-candidates re))
                  (nth (- offset total-old) proc)
                (- offset total-old))))))

(defun sallet-init-state (sources candidate-buffer)
  (let ((state (list (cons 'sources (-map 'sallet-init-source sources))
                     (cons 'current-buffer (current-buffer))
                     (cons 'prompt "")
                     (cons 'selected-candidate 0)
                     (cons 'candidate-buffer candidate-buffer))))
    (setq sallet-state state)
    state))

(defun sallet-render-source (state source offset)
  "Render.

OFFSET is the number of already rendered candidates before
this source.

Return number of rendered candidates."
  (with-current-buffer (sallet-state-get-candidate-buffer state)
    (insert "=== " (sallet-source-get-header source) " ===\n")
    (let* ((selected (sallet-state-get-selected-candidate state))
           (coffset (- selected offset))
           (i 0))
      (mapc
       (lambda (n)
         (insert (if (= coffset i) ">>" "  ")
                 (funcall
                  (sallet-source-get-renderer source)
                  (sallet-source-get-candidate source n)
                  (sallet-state-get-prompt state))
                 "\n")
         (when (= coffset i)
           (set-window-point (get-buffer-window (sallet-state-get-candidate-buffer state)) (point)))
         (setq i (1+ i)))
       (or (sallet-source-get-processed-candidates source)
           (number-sequence 0 (1- (length (sallet-source-get-candidates source))))))
      i)))

(defun sallet-render-state (state)
  "Render state."
  (with-current-buffer (sallet-state-get-candidate-buffer state)
    (erase-buffer)
    (let ((offset 0))
      (-each (sallet-state-get-sources state)
        (lambda (source)
          (setq offset (+ offset (sallet-render-source state source offset)))))
      (insert "\n\n"))))

(defun sallet (sources)
  (let* ((buffer (get-buffer-create "*Candidates*"))
         ;; make this lexically scoped
         (state (sallet-init-state sources buffer)))
    (pop-to-buffer buffer)
    (setq cursor-type nil)
    (sallet-render-state state)
    (condition-case var
        (minibuffer-with-setup-hook
            (lambda ()
              ;; TODO: figure out where to do which updates... this currently doesn't work
              (add-hook 'post-command-hook
                        (lambda ()
                          (sallet-state-set-prompt state (buffer-substring-no-properties 5 (point-max)))
                          (-each (sallet-state-get-sources state)
                            (lambda (source)
                              (-if-let (matcher (sallet-source-get-matcher source))
                                  (sallet-source-set-processed-candidates
                                   source
                                   (funcall matcher
                                            (sallet-source-get-candidates source)
                                            (sallet-state-get-prompt state)))
                                (sallet-source-set-processed-candidates source nil))))
                          (sallet-render-state state))
                        nil t)
              (add-hook 'after-change-functions
                        (lambda (_ _ _)
                          (sallet-state-set-selected-candidate state 0)
                          (-each (sallet-state-get-sources state)
                            (lambda (source)
                              (-when-let (generator (sallet-source-get-generator source))
                                (sallet-source-set-candidates
                                 source
                                 (funcall generator (sallet-state-get-prompt state)))))))
                        nil t))
          (read-from-minibuffer ">>> " nil (let ((map (make-sparse-keymap)))
                                             (set-keymap-parent map minibuffer-local-map)
                                             (define-key map (kbd "C-n") 'sallet-candidate-up)
                                             (define-key map (kbd "C-p") 'sallet-candidate-down)
                                             map))
          (sallet-default-action))
      ;; TODO: do we want `kill-buffer-and-window?'
      (quit (kill-buffer-and-window))
      (error (kill-buffer-and-window)))))

;; TODO: figure out how to avoid the global state here: sallet-state
(defun sallet-candidate-up ()
  (interactive)
  (when (< (sallet-state-get-selected-candidate sallet-state)
           (1- (sallet-state-get-number-of-all-candidates sallet-state)))
    (sallet-state-incf-selected-candidate sallet-state)))

(defun sallet-candidate-down ()
  (interactive)
  (when (> (sallet-state-get-selected-candidate sallet-state) 0)
    (sallet-state-decf-selected-candidate sallet-state)))

(defun sallet-default-action ()
  (kill-buffer-and-window)
  (-when-let ((source . cand) (sallet-state-get-selected-source sallet-state))
    (funcall (sallet-source-get-action source) cand)))

(defun sallet-buffer ()
  (interactive)
  (sallet (list
             sallet-source-buffer
             sallet-source-bookmarks-file-only)))

(defun sallet-occur ()
  (interactive)
  ;; TODO: find a way how to define this right in the source, this is a but clumsy
  ;; do we want to pass the entire state instead?
  (sallet (list (cons `(generator . ,(let ((buffer (current-buffer)))
                                         (lambda (prompt)
                                           (when (>= (length prompt) 2)
                                             (let (re)
                                               (with-current-buffer buffer
                                                 (goto-char (point-min))
                                                 (while (search-forward prompt nil t)
                                                   (push (cons (buffer-substring-no-properties (line-beginning-position) (line-end-position))
                                                               (point)) re))
                                                 (vconcat (nreverse re))))))))
                        sallet-source-occur))))

(provide 'sallet)
;;; sallet.el ends here
