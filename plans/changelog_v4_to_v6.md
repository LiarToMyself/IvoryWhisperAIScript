# Общий пул изменений: от `v4` к `v5` и `v6`

## Часть 1. Что изменено в `v5` (относительно `v4`)

1. **Устранение кракозябр при распаковке `translate_v4_argon.py` и в консоли**
   * **Было в v4**: `Get-Content '%~f0' -Raw` читал батник в `Windows-1251` и сохранял с `BOM`, ломая кириллицу (`Р’С‹Р±РµСЂРёС‚Рµ`).
   * **Стало в v5**: чтение через `[IO.File]::ReadAllText(..., [Text.Encoding]::UTF8)`, поиск последнего маркера `LastIndexOf`, запись в чистый `UTF-8` без `BOM`; в `.bat` и `.py` добавлены `PYTHONIOENCODING=utf-8`, `PYTHONUTF8=1` и `sys.stdout.reconfigure(encoding="utf-8")`.
   * **Зачем**: полный запрет двойной перекодировки при генерации `.py` и выводе текста.

2. **Поддержка `Python 3.14` и `Python 3.15` в установщике и запуске**
   * **Было в v4**: вызывался только `python` из `PATH`; на `Python 3.15` установка `faster-whisper` падала из-за отсутствия колеса `onnxruntime` ([onnxruntime #33271](https://github.com/microsoft/onnxruntime/issues/33271)).
   * **Стало в v5**: обход `python`, `py -3.14`, `py -3.15` без дублей (`SEEN_EXES`) с автоустановкой через [Python Install Manager 26.4](https://www.python.org/downloads/release/pymanager-264/). Ветка `<= 3.14` ставит полный стек с `onnxruntime`; ветка `>= 3.15` ставит [ctranslate2 >= 4.8.5](https://pypi.org/project/ctranslate2/), [av >= 19.0.2](https://pypi.org/project/av/), [numpy >= 2.5.4](https://pypi.org/project/numpy/), [tokenizers >= 0.23.3](https://pypi.org/project/tokenizers/) и `faster-whisper --no-deps`.
   * **Зачем**: рабочая установка и запуск на обеих версиях `Python`.

3. **Гибридный аудио-декодер и патч `PyAV 18/19+` (`_patched_av_open`, `_hybrid_decode_audio`)**
   * **Было в v4**: штатный вызов `faster-whisper 1.2.1` падал с `TypeError` на свежем `PyAV 19.x`, где удален аргумент `metadata_errors` ([faster-whisper #1589](https://github.com/SYSTRAN/faster-whisper/issues/1589)).
   * **Стало в v5**: шим `_patched_av_open` вырезает `metadata_errors`/`metadata_encoding` перед вызовом `av.open`; добавлен резервный декодер через `ffmpeg.exe` (`decode_audio_ffmpeg`) и тройная привязка `decode_audio` в модулях `audio`, `transcribe` и `faster_whisper`.
   * **Зачем**: чтение медиафайлов без сбоев на новых версиях `PyAV` и даже при отсутствии пакета `av`.

4. **Линейная склейка чанков `_linear_collect_chunks` ($O(N)$ вместо $O(N^2)$)**
   * **Было в v4**: в `faster-whisper 1.2.1` функция `collect_chunks` копировала массив через `np.concatenate` на каждом шаге цикла, вешая ПК на 2+ минуты на длинных видео ([faster-whisper #1690](https://github.com/SYSTRAN/faster-whisper/issues/1690)).
   * **Стало в v5**: бэкпортирован линейный сбор срезов с единичным `np.concatenate` в конце.
   * **Зачем**: склейка чанков на длинной записи идет 0.3 сек вместо 128 сек.

5. **Динамический `Silero VAD`, `Drag-and-Drop` и закрытие окна `tkinter`**
   * **Было в v4**: жесткий `vad_filter=True`, выбор файлов только через окно `tkinter` (которое не уничтожалось через `root.destroy()`).
   * **Стало в v5**: проверка `is_vad_available()` + откат `vad_filter=False` при сбое `onnxruntime` во время работы (с откатом записи `seek`/`truncate`), прием файлов из `sys.argv[1:]` при перетаскивании на `.bat` и вызов `root.destroy()`.
   * **Зачем**: удобный запуск перетаскиванием файлов и защита от падения при отсутствии `onnxruntime`.

## Часть 2. Что исправлено и дополнено в `v6` (поверх `v5`)

1. **Блокировка зависающего модуля `hf_xet` (`HF_HUB_DISABLE_XET=1`)**
   * **Было в v5**: при скачивании весов запускался фоновый Rust-модуль `hf_xet` внутри `snapshot_download`, который на Windows вешал загрузку на 0 байт ([разбор бага Xet](https://ai-muninn.com/en/blog/huggingface-download-stuck-zero-bytes-windows-ai-toolkit), [xet-core #850](https://github.com/huggingface/xet-core/issues/850)).
   * **Стало в v6**: в начало обоих `.bat` и `.py` добавлены `HF_HUB_DISABLE_XET=1` и `HF_HUB_ENABLE_HF_TRANSFER=0`.
   * **Зачем**: отключает зависающий Rust-клиент на Windows и переводит скачивание на чистый `HTTPS`.

2. **Убран принудительный `hf-mirror.com` и починен откат серверов**
   * **Было в v5**: стоял `HF_ENDPOINT=https://hf-mirror.com`, а смена `os.environ["HF_ENDPOINT"] = "https://huggingface.co"` внутри `except` игнорировалась библиотекой `huggingface_hub` (она кэширует `HF_ENDPOINT` один раз при импорте).
   * **Стало в v6**: удален принудительный `HF_ENDPOINT=https://hf-mirror.com`. Загрузка сначала идет с `https://huggingface.co`, а `https://hf-mirror.com` и резервные репозитории используются при сбое.
   * **Зачем**: реальное рабочее переключение между основным сервером и зеркалом.

3. **Прямая докачка модели с видимой шкалой (`ensure_model_downloaded`)**
   * **Было в v5**: загрузка шла через `WhisperModel(model_name)`, где `faster_whisper/utils.py` глушит шкалу через `disabled_tqdm` ([код faster-whisper](https://github.com/SYSTRAN/faster-whisper/blob/master/faster_whisper/utils.py)). Консоль молча висела на строке запуска.
   * **Стало в v6**: функция `ensure_model_downloaded()` до старта модели качает файлы CTranslate2 (`config.json`, `preprocessor_config.json`, `tokenizer.json`, `vocabulary.json`, `model.bin` из [mobiuslabsgmbh/faster-whisper-large-v3-turbo](https://huggingface.co/rtlingo/mobiuslabsgmbh-faster-whisper-large-v3-turbo/tree/main)) в `./models/large-v3-turbo/` через потоковый `requests` + `tqdm` (МБ, %, скорость) с докачкой `.part` (`Range`) и резервом на `urllib.request`. Заглушка `disabled_tqdm` заменена на `tqdm.tqdm`.
   * **Зачем**: наглядный прогресс скачивания 1.62 ГБ, докачка при обрыве связи и мгновенный оффлайн-старт (`local_files_only=True`) при следующих запусках.

4. **Проверка размера `model.bin` и поиск в системном кэше (`resolve_local_model_dir`)**
   * **Было в v5**: проверялось только наличие файла `./models/.../model.bin` (даже 0 байт) без проверки системного кэша.
   * **Стало в v6**: проверка `os.path.getsize(bin_path) > 50_000_000`, проверка `config.json` и поиск готовых снапшотов в `~/.cache/huggingface/hub/`.
   * **Зачем**: защита от падения на недокачанном файле и подхват ранее скачанных моделей из кэша.

5. **Автообновление `translate_v4_argon.py` прямо из `Run Whisper.bat`**
   * **Было в v5**: код `.py` распаковывался только из `Install Whisper.bat`; в ветке `:BRANCH_314` не были явно указаны `tqdm` и `requests`.
   * **Стало в v6**: свежий код `translate_v4_argon.py` встроен также в конец `Run Whisper.bat` и распаковывается автоматически при каждом запуске; в `:BRANCH_314` добавлены `tqdm` и `requests`.
   * **Зачем**: обновление кода срабатывает сразу при запуске `Run Whisper.bat` без долгой переустановки пакетов.
