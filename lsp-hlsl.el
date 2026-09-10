;;; lsp-hlsl.el --- lsp-mode client for HLSL-LSP -*- lexical-binding: t; -*-

;; Author: Sami Batuhan Basmaz Olmez <repelliuss@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (lsp-mode "9.0"))
;; Keywords: languages lsp hlsl shader
;; URL: https://github.com/repelliuss/lsp-shader-sense
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; lsp-mode client for the HLSL-LSP language server
;; (https://github.com/KStocky/HLSL-LSP).
;;
;; Registers `hlsl-lsp' as an lsp-mode client for HLSL buffers.  By
;; default `hlsl-ts-mode' is activated automatically; additional major
;; modes can be added via `lsp-hlsl-modes'.
;;
;; All settings are exposed as `lsp-defcustom' variables so that live
;; `setopt'/customize changes trigger a `DidChangeConfiguration'
;; notification and the server picks them up without a restart, exactly
;; as `lsp-shader-sense' does for shader-sense.
;;
;; Activate via `lsp-hlsl-setup' or the minor mode `lsp-hlsl-mode'.
;; Project-specific configuration (include paths, defines, etc.) is best
;; handled via `.dir-locals.el'.

;;; Code:

;; TODO: install script

(require 'lsp-mode)

(defgroup lsp-hlsl nil
  "lsp-mode client for the HLSL-LSP language server."
  :group 'lsp-mode
  :prefix "lsp-hlsl-"
  :link '(url-link "https://github.com/KStocky/HLSL-LSP"))

;;; Connection

(defcustom lsp-hlsl-executable
  (or (executable-find "hlsl-lsp")
      (executable-find "hlsl-lsp.exe")
      "hlsl-lsp")
  "Path to the `hlsl-lsp' executable."
  :type 'string
  :group 'lsp-hlsl)

(defcustom lsp-hlsl-args nil
  "Arguments passed to `lsp-hlsl-executable'."
  :type '(repeat string)
  :group 'lsp-hlsl)

;;; Major-mode activation

(defcustom lsp-hlsl-modes '(hlsl-ts-mode)
  "Major modes for which HLSL-LSP is activated automatically.
Each entry is registered in `lsp-language-id-configuration' when
`lsp-hlsl-mode' is enabled."
  :type '(repeat symbol)
  :group 'lsp-hlsl)

(defcustom lsp-hlsl-language-id "hlsl"
  "Language identifier sent to HLSL-LSP for all registered modes."
  :type 'string
  :group 'lsp-hlsl)

;;; HLSL-LSP settings

(lsp-defcustom lsp-hlsl-preprocessor-definitions nil
  "Alist of DXC preprocessor definitions sent to HLSL-LSP.
Each element is (NAME . VALUE).  Keys must be symbols.  VALUE may be a
string, a number, or a boolean; an empty string emits a value-less
define."
  :type '(alist :key-type (symbol :tag "Name")
                :value-type (choice (string :tag "String")
                                     (integer :tag "Number")
                                     (boolean :tag "Boolean")))
  :group 'lsp-hlsl
  :lsp-path "hlsl.preprocessorDefinitions")

(lsp-defcustom lsp-hlsl-additional-include-directories []
  "Vector of existing DXC include directories sent to HLSL-LSP.
Relative paths are resolved by the server from the folder containing
each shader."
  :type '(lsp-repeatable-vector directory)
  :group 'lsp-hlsl
  :lsp-path "hlsl.additionalIncludeDirectories")

(lsp-defcustom lsp-hlsl-virtual-directory-mappings nil
  "Alist mapping virtual include roots to existing directories on disk.
Each element is (VIRTUAL-PATH . REAL-PATH).  Keys must be symbols whose
name begins with `/' or `\\', primarily for Unreal-style paths.
Relative targets are resolved by the server from the containing
workspace folder."
  :type '(alist :key-type (symbol :tag "Virtual path")
                :value-type (string :tag "Real path"))
  :group 'lsp-hlsl
  :lsp-path "hlsl.virtualDirectoryMappings")

(lsp-defcustom lsp-hlsl-language-version "2021"
  "DXC HLSL language version (`-HV').  Nil means server default (2021)."
  :type '(choice (const :tag "Server default" nil)
                 (const :tag "HLSL 2016" "2016")
                 (const :tag "HLSL 2018" "2018")
                 (const :tag "HLSL 2021" "2021")
                 (const :tag "HLSL 202x" "202x"))
  :group 'lsp-hlsl
  :lsp-path "hlsl.languageVersion")

(lsp-defcustom lsp-hlsl-target-profile nil
  "DXC target profile, such as \"ps_6_6\", \"cs_6_7\", or \"lib_6_8\".
Nil means no override."
  :type '(choice (const :tag "Not set" nil) string)
  :group 'lsp-hlsl
  :lsp-path "hlsl.targetProfile")

(lsp-defcustom lsp-hlsl-entry-point nil
  "Shader entry point supplied to DXC.  Nil means no override."
  :type '(choice (const :tag "Not set" nil) string)
  :group 'lsp-hlsl
  :lsp-path "hlsl.entryPoint")

(lsp-defcustom lsp-hlsl-additional-arguments []
  "Vector of additional DXC arguments, for example \"-enable-16bit-types\"."
  :type '(lsp-repeatable-vector string)
  :group 'lsp-hlsl
  :lsp-path "hlsl.additionalArguments")

(lsp-defcustom lsp-hlsl-file-groups []
  "Vector of HLSL-LSP file groups sent via `hlsl.fileGroups'.
Mirrors the `hlsl.fileGroups' array documented for
`shadertoolsconfig.json', letting per-file-pattern settings (such as
`targetProfile' or `entryPoint') be pushed from the editor instead of
a config file on disk.

Must be a vector, not a list: `json-serialize'/`json-encode' cannot
distinguish a one-element list of alists from a single alist, so a
list here is misencoded as a JSON object instead of an array.

Each element is an alist with symbol keys.  `name' and `files' are
required; `files' is a vector of glob strings matched against the
file name, relative to the workspace folder.  Any `hlsl.*' setting may
also be included, keyed by a symbol whose name is the literal dotted
key, for example the symbol `hlsl.targetProfile'.

Example:
  (vector (list (cons \\='name \"Pixel shaders\")
                (cons \\='files [\"**/*_ps.hlsl\"])
                (cons (intern \"hlsl.targetProfile\") \"ps_6_6\")))"
  :type '(lsp-repeatable-vector (alist :key-type symbol :value-type sexp))
  :group 'lsp-hlsl
  :lsp-path "hlsl.fileGroups")

;;; Client registration

(defconst lsp-hlsl--server-id 'hlsl-lsp
  "lsp-mode server-id for the HLSL-LSP client.")

(defconst lsp-hlsl--section "hlsl"
  "Configuration section HLSL-LSP pulls its settings from.")

(defun lsp-hlsl--push-configuration (workspace)
  "Send the current HLSL-LSP settings to WORKSPACE.
Settings are pushed once on initialization so buffers opened before the
workspace was ready still get the correct configuration, mirroring
`lsp-shader-sense--push-configuration'.  Settings are read in a
workspace buffer so buffer-local values, for example ones from
`.dir-locals.el', are honored."
  (lsp-with-current-buffer (or (--first (lsp-buffer-live-p it)
                                       (lsp--workspace-buffers workspace))
                               (current-buffer))
    (with-lsp-workspace workspace
      (lsp--set-configuration
       (lsp-configuration-section lsp-hlsl--section)))))

(defun lsp-hlsl--register ()
  "Register the HLSL-LSP lsp-mode client."
  (dolist (mode lsp-hlsl-modes)
    (add-to-list 'lsp-language-id-configuration
                 (cons mode lsp-hlsl-language-id)))
  (lsp-register-client
   (make-lsp-client
    :new-connection (lsp-stdio-connection
                     (lambda ()
                       (cons lsp-hlsl-executable
                             lsp-hlsl-args)))
    :activation-fn (lsp-activate-on lsp-hlsl-language-id)
    :synchronize-sections (list lsp-hlsl--section)
    :initialized-fn #'lsp-hlsl--push-configuration
    :server-id lsp-hlsl--server-id)))

(defun lsp-hlsl--unregister ()
  "Remove the HLSL-LSP lsp-mode client."
  ;; `lsp-clients' is a hash table keyed by server-id in lsp-mode 9+.
  (remhash lsp-hlsl--server-id lsp-clients)
  (remhash (intern (concat (symbol-name lsp-hlsl--server-id) "-tramp"))
           lsp-clients)
  (dolist (mode lsp-hlsl-modes)
    (setq lsp-language-id-configuration
          (delete (cons mode lsp-hlsl-language-id)
                  lsp-language-id-configuration))))

(lsp-hlsl--register)

(provide 'lsp-hlsl)
;;; lsp-hlsl.el ends here
