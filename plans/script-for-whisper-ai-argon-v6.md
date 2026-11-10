# Что дополнено и исправлено относительно версии `Scriptv5`

1. **Блокировка зависающего модуля `hf_xet` (`Install Whisper.bat`, `Run Whisper.bat`, `translate_v4_argon.py`)**
   * **Как было в v5**: переменные `HF_HUB_DISABLE_XET=1` и `HF_HUB_ENABLE_HF_TRANSFER=0` не задавались. При вызове `WhisperModel` запускался фоновый Rust-модуль `hf_xet` внутри `snapshot_download`, который на Windows зависал на 0 байт ([разбор бага Xet](https://ai-muninn.com/en/blog/huggingface-download-stuck-zero-bytes-windows-ai-toolkit), [xet-core #850](https://github.com/huggingface/xet-core/issues/850)).
   * **Как стало**: в начало обоих `.bat` и в шапку `translate_v4_argon.py` добавлены `HF_HUB_DISABLE_XET=1` и `HF_HUB_ENABLE_HF_TRANSFER=0`.
   * **Почему так**: это полностью отключает зависающий Rust-транспорт на Windows и переводит загрузку на обычный `HTTPS`.

2. **Удаление принудительного зеркала `hf-mirror.com` и починка переключения серверов**
   * **Как было в v5**: в `Install Whisper.bat`, `Run Whisper.bat` и `translate_v4_argon.py` по умолчанию стоял китайский прокси `HF_ENDPOINT=https://hf-mirror.com`. В функции `instantiate_whisper_model` при ошибке менялась переменная `os.environ["HF_ENDPOINT"] = "https://huggingface.co"`.
   * **Как стало**: принудительный `HF_ENDPOINT=https://hf-mirror.com` убран из батников и `.py`. Загрузка сначала идет напрямую с официального `https://huggingface.co`, а `https://hf-mirror.com` используется только как запасной адрес.
   * **Почему так**: библиотека `huggingface_hub` считывает `HF_ENDPOINT` только один раз в момент `import faster_whisper`. Поэтому смена `os.environ["HF_ENDPOINT"]` внутри блока `except` в версии `v5` не срабатывала — скрипт повторно стучался на тот же недоступный `hf-mirror.com`.

3. **Прямая докачка модели с видимой шкалой прогресса (`ensure_model_downloaded` и `_download_single_file`)**
   * **Как было в v5**: скрипт передавал имя `"large-v3-turbo"` напрямую в `WhisperModel(...)`. Внутри `faster_whisper/utils.py` жестко прописана заглушка `tqdm_class=disabled_tqdm` ([код faster-whisper](https://github.com/SYSTRAN/faster-whisper/blob/master/faster_whisper/utils.py)), которая скрывает шкалу скачивания. В итоге консоль молча висела на строке `[*] Запуск 'large-v3-turbo'...`.
   * **Как стало**: написана функция `ensure_model_downloaded()`, которая вызывается до инициализации `WhisperModel`. Она по очереди качает нужные файлы формата CTranslate2 (`config.json`, `preprocessor_config.json`, `tokenizer.json`, `vocabulary.json`, `model.bin` из репозитория [mobiuslabsgmbh/faster-whisper-large-v3-turbo](https://huggingface.co/rtlingo/mobiuslabsgmbh-faster-whisper-large-v3-turbo/tree/main)) прямо в папку `./models/large-v3-turbo/`. Загрузка идет через потоковый `requests` с видимой полосой `tqdm` (объем в МБ, проценты, скорость) и поддержкой докачки оборванных файлов `.part` через HTTP-заголовок `Range` (плюс резерв через `urllib.request`, если `requests` не установлен). Также `faster_whisper.utils.disabled_tqdm` заменен на `tqdm.tqdm`.
   * **Почему так**: пользователь сразу видит скорость и прогресс скачивания 1.62 ГБ, обрыв интернета не сбрасывает скачанные мегабайты, а после первой загрузки модель запускается из `./models/large-v3-turbo/` за 1–2 секунды полностью оффлайн (`local_files_only=True`).

4. **Проверка целостности `model.bin` и поиск в системном кэше (`resolve_local_model_dir`)**
   * **Как было в v5**: функция `resolve_local_model_dir` проверяла только `os.path.isfile("model.bin")` в `./models/`, не проверяя размер файла и не заглядывая в стандартный кэш Hugging Face.
   * **Как стало**: добавлена проверка размера `os.path.getsize(bin_path) > 50_000_000` и проверка наличия `config.json`, а также обход стандартного кэша `~/.cache/huggingface/hub/models--...`.
   * **Почему так**: если при прошлом зависании создался пустой или битый `model.bin`, скрипт не упадет на нем, а докачает файл. А если модель уже была скачана ранее в системный кэш, скрипт найдет ее без повторной загрузки.

5. **Автономное обновление `translate_v4_argon.py` прямо из `Run Whisper.bat`**
   * **Как было в v5**: код `translate_v4_argon.py` распаковывался только при запуске `Install Whisper.bat`. Если пользователь запускал `Run Whisper.bat` со старым `translate_v4_argon.py`, новые правки не применялись. Также в ветке `:BRANCH_314` внутри `Install Whisper.bat` пакеты `tqdm` и `requests` не перечислялись явно.
   * **Как стало**: полный обновленный код `translate_v4_argon.py` встроен также в конец `Run Whisper.bat` (после `exit /b 0` и маркера `#---PYTHON_CODE_START---#`). При старте `Run Whisper.bat` сам обновляет `translate_v4_argon.py` в UTF-8 без BOM перед запуском Python. В `:BRANCH_314` файла `Install Whisper.bat` явно добавлены `tqdm` и `requests`.
   * **Почему так**: достаточно открыть `Run Whisper.bat`, не тратя время на повторную переустановку всех библиотек через `Install Whisper.bat`.
