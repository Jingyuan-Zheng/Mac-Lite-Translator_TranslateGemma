import sys
import tkinter as tk
import AppKit
from tkinter import ttk, messagebox, filedialog
from threading import Thread, Event
import os
import time
import select
import socket

# Import required MLX-LM functions
try:
    from mlx_lm import load, generate, stream_generate
except ImportError:
    print("Error: Please install required packages: pip install mlx-lm")
    sys.exit(1)
    
try:
    from langdetect import detect, DetectorFactory
    DetectorFactory.seed = 0 # Make results reproducible
    HAS_LANGDETECT = True
except ImportError:
    HAS_LANGDETECT = False
    print("Warning: 'langdetect' library not found. Auto-detection for non-CJK languages will be weak.")

# ================= USER CONFIGURATION (用户配置区) =================
# 请在这里设置你的母语和想要学习/翻译的主要外语
# 请确保填写的名称必须在下方的 self.languages 列表中存在
# Determine your Native Language and Primary Foreign Language here.
# Make sure the names exist in the self.languages list.

USER_NATIVE_LANG = "English"       # 你的母语 (Your Native Language)
USER_PRIMARY_FOREIGN_LANG = "Español"  # 你的主要外语 (Your Primary Foreign Language)

# ===================================================================

class HybridBackend:
    def __init__(self, app, model_path):
        self.app = app
        self.model_path = model_path
        self.model = None
        self.tokenizer = None
        self.processing_thread = None
        self.stop_event = Event()
        self.current_gen_id = 0
       
        self.lang_map = {
            "简体中文": "zh",       
            "繁體中文": "zh-Hant",
            "English": "en",
            "日本語": "ja",
            "한국어": "ko",
            "Français": "fr",
            "Deutsch": "de",
            "Italiano": "it",
            "Español": "es",
            "Русский": "ru",
            "Português": "pt",
            "العربية": "ar",
            "हिन्दी": "hi",
            "Malti": "mt"
        }

    def start_loading(self):
        def _load():
            print(f"Backend: Loading LLM model from {self.model_path}...")
            try:
                model_config = {"trust_remote_code": True}
                
                self.model, self.tokenizer = load(
                    self.model_path, 
                    model_config=model_config
                )
                print("Backend: Model loaded.")
                self.app.root.after(0, self.app.switch_to_main_interface)
            except Exception as e:
                err_msg = str(e)
                print(f"Load Error: {err_msg}")
                def show_error():
                    self.app.loading_label.config(text="Model Load Failed", fg="red")
                    messagebox.showerror("Model Load Error", f"Failed to load model:\n{err_msg}")
                self.app.root.after(0, show_error)
        
        Thread(target=_load).start()
            
    def detect_source_lang(self, text):
        if any('\u3040' <= c <= '\u30ff' for c in text): return "ja"
        if any('\u4e00' <= c <= '\u9fff' for c in text): return "zh"
        return "en"

    def stop(self):
        print("Backend: Stop signal received.")
        self.stop_event.set()

    def translate(self, input_content, target_lang_name, style="Default"):
        self.stop_event.set()
        
        self.current_gen_id += 1
        my_gen_id = self.current_gen_id
        
        target_code = self.lang_map.get(target_lang_name, "en")
        clean_input = input_content.strip().strip('"').strip("'")

        old_thread = self.processing_thread

        def _thread_manager():
            if old_thread and old_thread.is_alive():
                old_thread.join()

            self.stop_event.clear()
            self._unified_process(clean_input, target_code, style, my_gen_id)

        new_thread = Thread(target=_thread_manager)
        self.processing_thread = new_thread
        new_thread.start()

    def _unified_process(self, input_content, target_code, style, gen_id):
        if not self.model: return
        
        try:
            print(f"Backend: Mode = Text. Target: {target_code}, Style: {style}")
            
            source_code = self.detect_source_lang(input_content)
            
            self.app.start_loading_animation()

            processed_text = input_content
            warning_prefix = ""
            
            # If style is Default, auto-detect single word/phrase
            if style == "Default":
                clean_str = input_content.strip()
                has_punctuation = any(char in "，。！？；：,.!?;:" for char in clean_str)
                space_count = clean_str.count(" ")
                cjk_count = sum(1 for char in clean_str if '\u4e00' <= char <= '\u9fff' or '\u3040' <= char <= '\u30ff')
                
                is_likely_word = False

                if cjk_count > 0:
                    # Chinese/Japanese/Korean logic: no punctuation, short length
                    if not has_punctuation and len(clean_str) <= 6:
                        is_likely_word = True
                else:
                    # Western logic: no punctuation, no spaces (or only a few spaces like compound words), medium length
                    # Here we define: no punctuation and (no spaces or very short length)
                    if not has_punctuation and (space_count == 0 or len(clean_str) < 20):
                        is_likely_word = True
                
                if is_likely_word:
                    print(f"Backend: Auto-detect single word/phrase '{clean_str}'. Switching to Dictionary style.")
                    style = "Dictionary"
            
            # Dictionary Style Processing
            if style == "Dictionary":
                
                cjk_count = sum(1 for char in input_content if '\u4e00' <= char <= '\u9fff' or '\u3040' <= char <= '\u30ff')
                

                has_punctuation = any(char in "，。！？；：,.!?;:" for char in input_content)
                has_spaces = len(input_content.split()) > 1
                
                is_sentence = (
                    has_spaces or 
                    has_punctuation or 
                    len(input_content) > 20 or 
                    cjk_count > 6
                )
                
                if is_sentence:
                    warning_prefix = "⚠️ [Mode Switch: Input detected as a phrase/sentence. Switching to Default style...]\n\n"
                    style = "Default"
                else:
                    # Dictionary Prompt Construction
                    prefix = (
                        "You are a dictionary formatter.\n"
                        "Your task is to output EXACTLY 5 lines and NOTHING ELSE.\n"
                        "Any extra text, titles, labels, numbering, markdown, or explanations are STRICTLY FORBIDDEN.\n\n"

                        "FORMAT (STRICT):\n"
                        "Line 1: IPA pronunciation enclosed in slashes, and ONLY IPA. Example: /kæt/\n"
                        "Line 2: Part of speech ONLY. Example: noun, verb, adjective\n"
                        f"Line 3: Definition written in {target_code}. No labels.\n"
                        "Line 4: List one example sentence in the original language of WORD. No labels.\n"
                        f"Line 5: Translation of line 4 written in {target_code}. No labels.\n\n"

                        "NEGATIVE CONSTRAINTS (DO NOT DO THESE):\n"
                        "- Do NOT use words like Definition, Example, Translation\n"
                        "- Do NOT use headers, bullet points, numbers, or markdown\n"
                        "- Do NOT add explanations or notes\n"
                        "- Do NOT repeat the word\n\n"

                        "WORD: "
                    )
                    processed_text = prefix + input_content

            # Other Styles Processing
            if style == "Academic":
                prefix = f"(Translate the following text into {target_code} using a formal, academic, and scientific tone):\n"
                processed_text = prefix + input_content
            elif style == "Web Chat":
                prefix = f"(Translate the following text into {target_code} using an casual tone suitable for online messaging. You can use common abbreviations, slang like a real person would):\n"
                processed_text = prefix + input_content
            elif style == "Casual":
                prefix = f"(Translate the following text into {target_code} using a natural, casual, and conversational tone):\n"
                processed_text = prefix + input_content
            
            # Construct Payload and Prompt
            payload = {
                "type": "text",
                "source_lang_code": source_code,
                "target_lang_code": target_code,
                "text": processed_text, 
                "image": None  
            }
            messages = [{"role": "user", "content": [payload]}]

            if hasattr(self.tokenizer, "apply_chat_template"):
                prompt = self.tokenizer.apply_chat_template(
                    messages,
                    tokenize=False,
                    add_generation_prompt=True
                )
            else:
                prompt = f"Translate from {source_code} to {target_code}:\n{processed_text}"

            gen_kwargs = {
                "max_tokens": 1024,
            }

            print("Backend: Starting stream generation...")
            
            is_first_token = True
            
            for response in stream_generate(self.model, self.tokenizer, prompt, **gen_kwargs):
                if self.stop_event.is_set() or gen_id != self.current_gen_id:
                    self.app.stop_loading_animation()
                    self.app.update_translation_display("\n[Stopped]", is_append=True)
                    return

                text_chunk = response.text
                
                stop_tokens = ["<end_of_turn>", "<eos>", "<bos>"]
                should_stop = False
                
                for token in stop_tokens:
                    if token in text_chunk:
                        should_stop = True
                        text_chunk = text_chunk.replace(token, "")
                
                if text_chunk:
                    if is_first_token:
                        self.app.stop_loading_animation()
                        self.app.update_translation_display("", is_append=False)
                        
                        if warning_prefix:
                            self.app.update_translation_display(warning_prefix, is_append=True)
                            
                        is_first_token = False
                    
                    self.app.update_translation_display(text_chunk, is_append=True)

                if should_stop:
                    break
            
            self.app.stop_loading_animation()
            print("Backend: Finished.")

        except Exception as e:
            self.app.stop_loading_animation()
            import traceback
            traceback.print_exc()
            self.app.update_translation_display(f"Error: {e}", is_append=False)

# --- Utility Functions ---
def contains_japanese_kana(text):
    for char in text:
        if '\u3040' <= char <= '\u30ff':
            return True
    return False
def contains_chinese_kanji(text):
    for char in text:
        if '\u4e00' <= char <= '\u9fff':
            return True
    return False

class TranslatorApp:
    def __init__(self, root, initial_text, translate_cb, stop_cb):
        self.root = root
        self.translate_cb = translate_cb
        self.stop_cb = stop_cb
        self.input_text = initial_text
        self.is_original_expanded = False
        self.style_var = tk.StringVar(value="Default")
        
        self.loading_job = None
        self.is_loading = False
        self.spinner_frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        self.spinner_idx = 0
       
        self.languages = [
            "简体中文", 
            "繁體中文", 
            "English", 
            "日本語", 
            "한국어", 
            "Français", 
            "Deutsch", 
            "Italiano", 
            "Español", 
            "Русский",
            "Português",
            "العربية",
            "हिन्दी",
            "Malti"
        ]

        # Language code to name mapping for detection
        self.code_to_name_map = {
            "zh-cn": "简体中文", "zh": "简体中文",
            "zh-tw": "繁體中文",
            "en": "English",
            "ja": "日本語",
            "ko": "한국어",
            "fr": "Français",
            "de": "Deutsch",
            "it": "Italiano",
            "es": "Español",
            "ru": "Русский",
            "pt": "Português",
            "ar": "العربية",
            "hi": "हिन्दी",
            "mt": "Malti"
        }

        self.styles = ["Default", "Academic", "Web Chat", "Casual", "Dictionary"]

        self.last_foreign_lang = USER_PRIMARY_FOREIGN_LANG

        self.setup_window()
        self.setup_macos_integration()
        self.show_loading_screen()

    def setup_window(self):
        self.root.title("Translator")
        screen_width = self.root.winfo_screenwidth()
        screen_height = self.root.winfo_screenheight()
        x = (screen_width - 500) // 2
        y = (screen_height - 500) // 2
        self.root.geometry(f"500x520+{x}+{y}")
        self.root.resizable(False, False)
        self.root.lift()
        self.root.focus_force()
        self.root.protocol("WM_DELETE_WINDOW", self.on_closing)

    def setup_macos_integration(self):
        info = AppKit.NSBundle.mainBundle().infoDictionary()
        info['CFBundleName'] = "Translator"
        current_dir = os.path.dirname(os.path.abspath(__file__))
        icon_path = os.path.join(current_dir, "translator.icns")
        if os.path.exists(icon_path):
            image = AppKit.NSImage.alloc().initWithContentsOfFile_(icon_path)
            if image:
                AppKit.NSApp.setApplicationIconImage_(image)
        app = AppKit.NSApp
        app.setActivationPolicy_(AppKit.NSApplicationActivationPolicyRegular)
        app.activateIgnoringOtherApps_(True)
        
    def show_loading_screen(self):
        self.loading_frame = tk.Frame(self.root)
        self.loading_frame.pack(expand=True, fill='both')
        self.loading_label = tk.Label(self.loading_frame, text="Loading TranslateGemma...\nPlease wait", font=(".AppleSystemUIFont", 14))
        self.loading_label.pack(pady=(150, 20))
        self.progress = ttk.Progressbar(self.loading_frame, orient="horizontal", length=300, mode="indeterminate")
        self.progress.pack(pady=10)
        self.progress.start(10)
        self.request_id = AppKit.NSApp.requestUserAttention_(AppKit.NSCriticalRequest)

    def switch_to_main_interface(self):
        if hasattr(self, 'request_id'):
            AppKit.NSApp.cancelUserAttentionRequest_(self.request_id)
        self.loading_frame.destroy()
        self.init_main_widgets()
        self.trigger_translation()

    def init_main_widgets(self):
        tk.Label(self.root, text="Original Text:", anchor='w').pack(pady=(10, 0), padx=10, anchor='w')
        self.original_frame = tk.Frame(self.root)
        self.original_frame.pack(padx=10, pady=(5, 5), fill=tk.BOTH, expand=True)
        self.original_scrollbar = ttk.Scrollbar(self.original_frame, orient=tk.VERTICAL)
        self.original_text = tk.Text(self.original_frame, wrap=tk.WORD, height=1, width=50, yscrollcommand=self.original_scrollbar.set)
        self.original_scrollbar.config(command=self.original_text.yview)
        self.original_text.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        self.original_text.insert(tk.END, self.input_text)
        
        orig_control_frame = tk.Frame(self.root)
        orig_control_frame.pack(pady=2)
        
        self.toggle_button = ttk.Button(orig_control_frame, text="⬇️ Expand Original", command=self.toggle_original)
        self.toggle_button.pack(side=tk.LEFT, padx=5)
        
        self.update_btn = ttk.Button(orig_control_frame, text="🔄 Update", command=self.update_and_translate)
        self.update_btn.pack(side=tk.LEFT, padx=5)
        
        self.swap_btn = ttk.Button(orig_control_frame, text="🔃 Swap", command=self.swap_and_translate)
        self.swap_btn.pack(side=tk.LEFT, padx=5)

        self.stop_btn = ttk.Button(orig_control_frame, text="🛑 Stop", command=self.trigger_stop)
        self.stop_btn.pack(side=tk.LEFT, padx=5)

        selection_frame = tk.Frame(self.root)
        selection_frame.pack(pady=(5, 0), padx=20, fill=tk.X)
        
        lang_sub_frame = tk.Frame(selection_frame)
        lang_sub_frame.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 5))
        tk.Label(lang_sub_frame, text="Target:", font=(".AppleSystemUIFont", 11, "bold")).pack(anchor='w')
        self.lang_combobox = ttk.Combobox(lang_sub_frame, values=self.languages, state="readonly")
        self.auto_select_language()
        self.lang_combobox.pack(fill=tk.X)
        self.lang_combobox.bind("<<ComboboxSelected>>", lambda e: self.trigger_translation())

        style_sub_frame = tk.Frame(selection_frame)
        style_sub_frame.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(5, 0))
        tk.Label(style_sub_frame, text="Style:", font=(".AppleSystemUIFont", 11, "bold")).pack(anchor='w')
        
        self.style_combobox = ttk.Combobox(style_sub_frame, textvariable=self.style_var, values=self.styles, state="readonly")
        self.style_combobox.pack(fill=tk.X)
        self.style_combobox.bind("<<ComboboxSelected>>", lambda e: self.trigger_translation())

        tk.Label(self.root, text="Translation:", anchor='w').pack(pady=(10, 0), padx=10, anchor='w')
        self.translation_frame = tk.Frame(self.root)
        self.translation_frame.pack(padx=10, pady=(5, 10), fill=tk.BOTH, expand=True)
        self.translation_scrollbar = ttk.Scrollbar(self.translation_frame, orient=tk.VERTICAL)
        self.translation_text = tk.Text(self.translation_frame, wrap=tk.WORD, height=8, width=50, yscrollcommand=self.translation_scrollbar.set)
        self.translation_scrollbar.config(command=self.translation_text.yview)
        self.translation_text.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        self.translation_text.bind("<Configure>", self.update_translation_scrollbar)
        
        button_frame = tk.Frame(self.root)
        button_frame.pack(pady=(0, 15))
        self.copy_orig_btn = ttk.Button(button_frame, text="📄 Copy Original", command=self.copy_original)
        self.copy_orig_btn.pack(side=tk.LEFT, padx=10)
        self.copy_trans_btn = ttk.Button(button_frame, text="📝 Copy Translation", command=self.copy_translation)
        self.copy_trans_btn.pack(side=tk.LEFT, padx=10)
        
        self.create_menu()

    def start_loading_animation(self):

        self.root.after(0, self._start_anim_logic)

    def _start_anim_logic(self):
        self._stop_anim_logic() 
        self.is_loading = True
        self.spinner_idx = 0
        self.translation_text.delete(1.0, tk.END)
        self._animate_step()

    def _animate_step(self):
        if not self.is_loading:
            return
        
        frame = self.spinner_frames[self.spinner_idx % len(self.spinner_frames)]
        
        self.translation_text.delete(1.0, tk.END)
        self.translation_text.insert(tk.END, f"Translating {frame}")
        
        self.spinner_idx += 1

        self.loading_job = self.root.after(80, self._animate_step)

    def stop_loading_animation(self):
        self.root.after(0, self._stop_anim_logic)

    def _stop_anim_logic(self):
        self.is_loading = False
        if self.loading_job:
            try:
                self.root.after_cancel(self.loading_job)
            except:
                pass
            self.loading_job = None

    def open_text_file_dialog(self):
        file_path = filedialog.askopenfilename(
            title="Select a Text File",
            filetypes=[
                ("Text Files", "*.txt *.md *.json *.py *.js *.html *.csv"),
                ("All Files", "*.*")
            ]
        )
        if file_path:
            try:
                with open(file_path, 'r', encoding='utf-8') as f:
                    content = f.read()
                
                self.original_text.delete(1.0, tk.END)
                self.original_text.insert(tk.END, content)
                self.input_text = content
                
                if not self.is_original_expanded:
                    self.toggle_original()
                
                self.update_and_translate()
            except Exception as e:
                messagebox.showerror("Read Error", f"Failed to read file:\n{str(e)}")

    def create_menu(self):
        menubar = tk.Menu(self.root)
        
        file_menu = tk.Menu(menubar, tearoff=0)
        menubar.add_cascade(label="File", menu=file_menu)
        file_menu.add_command(label="Open Text File...", command=self.open_text_file_dialog, accelerator="Cmd+O")
        self.root.bind("<Command-o>", lambda e: self.open_text_file_dialog())
       
        edit_menu = tk.Menu(menubar, tearoff=0)
        menubar.add_cascade(label="Edit", menu=edit_menu)
        edit_menu.add_command(label="Undo", accelerator="Cmd+Z", command=lambda: self.root.focus_get().event_generate("<<Undo>>"))
        edit_menu.add_separator()
        edit_menu.add_command(label="Cut", accelerator="Cmd+X", command=lambda: self.root.focus_get().event_generate("<<Cut>>"))
        edit_menu.add_command(label="Copy", accelerator="Cmd+C", command=lambda: self.root.focus_get().event_generate("<<Copy>>"))
        edit_menu.add_command(label="Paste", accelerator="Cmd+V", command=lambda: self.root.focus_get().event_generate("<<Paste>>"))
        edit_menu.add_separator()
        edit_menu.add_command(label="Copy Original Text", command=self.copy_original)
        edit_menu.add_command(label="Copy Translation", command=self.copy_translation)
       
        action_menu = tk.Menu(menubar, tearoff=0)
        menubar.add_cascade(label="Actions", menu=action_menu)
        action_menu.add_command(label="Expand/Collapse Original", command=self.toggle_original, accelerator="Command-E")
        action_menu.add_command(label="Update & Translate", command=self.update_and_translate, accelerator="Command-R")
        action_menu.add_command(label="Swap Original/Translation", command=self.swap_and_translate, accelerator="Command-T")
        self.root.bind("<Command-t>", lambda e: self.swap_and_translate())
        action_menu.add_command(label="Stop Translation", command=self.trigger_stop, accelerator="Command-.")
        self.root.bind("<Command-period>", lambda e: self.trigger_stop())
        self.root.bind("<Command-r>", lambda e: self.update_and_translate())

        style_menu = tk.Menu(menubar, tearoff=0)
        menubar.add_cascade(label="Style", menu=style_menu)
        for style in self.styles:
            style_menu.add_radiobutton(
                label=style,
                variable=self.style_var,
                value=style,
                command=self.trigger_translation
            )

        lang_menu = tk.Menu(menubar, tearoff=0)
        menubar.add_cascade(label="Language", menu=lang_menu)
        for idx, lang in enumerate(self.languages):
            lang_menu.add_command(
                label=lang, 
                command=lambda i=idx: [self.lang_combobox.current(i), self.trigger_translation()]
            )
        
        window_menu = tk.Menu(menubar, name='window', tearoff=0)
        menubar.add_cascade(label="Window", menu=window_menu)
        self.root.config(menu=menubar)

    def detect_best_language(self, text):

            # Core detection logic: input text, return detected language name (e.g., 'English', '简体中文')

            text = text.strip()
            if not text:
                return None
                
            detected_name = None

            # CJK Detection First
            if contains_japanese_kana(text):
                detected_name = "日本語"
            elif contains_chinese_kanji(text):
                # 智能判定简繁体：如果用户母语是繁体，就优先认为是繁体，否则默认简体
                if USER_NATIVE_LANG == "繁體中文":
                    detected_name = "繁體中文"
                else:
                    detected_name = "简体中文"
            elif any('\uac00' <= char <= '\ud7a3' for char in text):
                detected_name = "한국어"
            
            # For non-CJK, use langdetect if available
            if not detected_name and HAS_LANGDETECT:
                try:
                    code = detect(text)
                    detected_name = self.code_to_name_map.get(code.lower())
                except Exception:
                    pass
                    
            return detected_name

    def auto_select_language(self):

            # GUI Logic: auto-select target language based on input text

            text = self.input_text.strip()
            if not text:
                return

            detected_lang_name = self.detect_best_language(text)

            target_lang_name = USER_NATIVE_LANG # Default target is Native Language

            if detected_lang_name:
                print(f"Auto-Detect: Input detected as '{detected_lang_name}'")
                
                if detected_lang_name == USER_NATIVE_LANG:
                    target_lang_name = USER_PRIMARY_FOREIGN_LANG
                else:
                    target_lang_name = USER_NATIVE_LANG
            
            try:
                target_index = self.languages.index(target_lang_name)
                self.lang_combobox.current(target_index)
            except ValueError:
                self.lang_combobox.current(0)

    def toggle_original(self):
        if self.is_original_expanded:
            self.original_text.config(height=1)
            self.toggle_button.config(text="⬇️ Expand Original")
            self.original_scrollbar.pack_forget()
        else:
            self.original_text.config(height=10)
            self.toggle_button.config(text="⬆️ Collapse Original")
            self.original_scrollbar.pack(side=tk.RIGHT, fill=tk.Y)
        self.is_original_expanded = not self.is_original_expanded

    def update_translation_scrollbar(self, event=None):
        if self.translation_text.yview()[1] < 1.0:
            self.translation_scrollbar.pack(side=tk.RIGHT, fill=tk.Y)
        else:
            self.translation_scrollbar.pack_forget()

    def update_and_translate(self):
        new_content = self.original_text.get(1.0, tk.END).strip()
        if not new_content:
            messagebox.showwarning("Warning", "Original text is empty!")
            return
        self.input_text = new_content
        self.trigger_translation()
        
    def swap_and_translate(self):
            # Get the cleaned translation text
            trans_text = self.get_clean_translation()
            if not trans_text:
                return

            current_source_text = self.original_text.get(1.0, tk.END).strip()
            detected_origin_lang = self.detect_best_language(current_source_text)
            
            current_target_lang = self.lang_combobox.get()

            self.original_text.delete(1.0, tk.END)
            self.original_text.insert(tk.END, trans_text)
            self.input_text = trans_text
            self.translation_text.delete(1.0, tk.END)

            new_target = None

            if detected_origin_lang and detected_origin_lang != current_target_lang:
                new_target = detected_origin_lang
                
                if new_target != USER_NATIVE_LANG:
                    self.last_foreign_lang = new_target

            else:
                if current_target_lang == USER_NATIVE_LANG:
                    new_target = self.last_foreign_lang
                else:
                    new_target = USER_NATIVE_LANG
                    self.last_foreign_lang = current_target_lang

            if new_target:
                try:
                    target_index = self.languages.index(new_target)
                    self.lang_combobox.current(target_index)
                except ValueError:
                    pass

            self.trigger_translation()

    def trigger_translation(self):
        target_lang = self.lang_combobox.get()
        if target_lang != USER_NATIVE_LANG:
            self.last_foreign_lang = target_lang
        style = self.style_combobox.get()
        source_text = self.input_text
        
        self.translate_cb(source_text, target_lang, style)

    def trigger_stop(self):
        self.stop_cb()

    def update_translation_display(self, text, is_append=True):
        self.root.after(0, lambda: self._safe_update_text(text, is_append))

    def _safe_update_text(self, text, is_append):

        if self.is_loading:
            self._stop_anim_logic()

        if not is_append:
            self.translation_text.delete(1.0, tk.END)
            self.translation_text.insert(tk.END, text)
        else:
            current_content = self.translation_text.get(1.0, tk.END).strip()
            if current_content.startswith("Translating"):
                self.translation_text.delete(1.0, tk.END)
            
            self.translation_text.insert(tk.END, text)

        self.translation_text.see(tk.END)

    def copy_original(self):
        content = self.original_text.get(1.0, tk.END).strip()
        self.root.clipboard_clear()
        self.root.clipboard_append(content)
        self.root.update()
        self._show_copy_feedback(self.copy_orig_btn)
        
    def get_clean_translation(self):
        content = self.translation_text.get(1.0, tk.END).strip()
        
        # Remove mode switch warning and stopped message
        warning_msg = "⚠️ [Mode Switch: Input detected as a phrase/sentence. Switching to Default style...]"
        stopped_msg = "[Stopped]"
        
        if warning_msg in content:
            content = content.replace(warning_msg, "").strip()
            
        if content.endswith(stopped_msg):
            content = content.replace(stopped_msg, "").strip()
            
        if content.startswith("Translating "):
            return ""

        return content

    def copy_translation(self):
            content = self.get_clean_translation()
            if not content:
                return # If translation is empty, do nothing

            self.root.clipboard_clear()
            self.root.clipboard_append(content)
            self.root.update()
            self._show_copy_feedback(self.copy_trans_btn)

    def _show_copy_feedback(self, btn):
        old_text = btn.cget("text")
        btn.config(text="✅ Copied!")
        self.root.after(2000, lambda: btn.config(text=old_text))

    def on_closing(self):
        self.root.destroy()
        os._exit(0)

# --- Main Entry Point ---
if __name__ == "__main__":
    
    LOCK_PORT = 54321
    try:
        instance_lock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        instance_lock.bind(("127.0.0.1", LOCK_PORT))
    except socket.error:
        cmd = """osascript -e 'display dialog "The Translator application is already active.\nPlease check your open windows or dock." with title "App is already running" buttons {"OK"} default button "OK" with icon stop'"""
        os.system(cmd)
        sys.exit(0)
    
    initial_input = "Hello, waiting for input..."
    if len(sys.argv) > 1:
        initial_input = " ".join(sys.argv[1:])
    elif select.select([sys.stdin], [], [], 0.0)[0]:
        content = sys.stdin.read().strip()
        if content:
            initial_input = content

    root = tk.Tk()
    backend = None
   
    def on_translate(text, lang, style):
        if backend:
            backend.translate(text, lang, style)
    
    def on_stop():
        if backend:
            backend.stop()
            
    app = TranslatorApp(root, initial_input, on_translate, on_stop)
   
    MODEL_PATH = "mlx-community/translategemma-12b-it-4bit"
   
    backend = HybridBackend(app, model_path=MODEL_PATH)
    backend.start_loading()
   
    root.mainloop()
