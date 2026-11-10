# Технический отчёт: Рефакторинг и модернизация Scripts for Whisper v4 Argon (Ноябрь 2026)

> **Дата релиза:** 10 ноября 2026 г.  
> **Репозиторий:** [LiarToMyself/IvoryWhisperAIScript](https://github.com/LiarToMyself/IvoryWhisperAIScript)  
> **Целевые платформы:** Windows 10/11 x64, Python 3.14.x (Stable) и Python 3.15.x (Oct 2026 Release), GPU NVIDIA GeForce GTX 1650 Ti (4 GB VRAM, CUDA 12 + cuDNN 9) / CPU fallback.

---

## 1. Резюме выполненных работ

В ходе аудита исходных файлов (`Install Whisper.bat`, `Run Whisper.bat`, `translate_v4_argon.py`) и предварительного отчёта от модели Gemini 3.8 Flash (`Whisper_AI_Technical_Report_2026-gemini-3.8FH.md`) были выявлены и устранены как исходные дефекты скриптов, так и **критические инженерные ошибки самой модели 3.8 Flash**, из-за которых предложенный ею вариант падал при запуске и на Python 3.14, и на Python 3.15.

Итоговое решение обеспечивает:
1. Полную работоспособность на **Python 3.14.x** и **Python 3.15.x** (через `python` в `PATH` и через [Python Install Manager 26.4](https://www.python.org/downloads/release/pymanager-264/) `py -3.14` / `py -3.15`).
2. Гарантированное отсутствие кракозябр (двойной перекодировки `UTF-8 -> CP1251 -> UTF-8`) при генерации `translate_v4_argon.py` из батника и при выводе в консоль Windows.
3. Автоматический обход несовместимости `faster-whisper 1.2.1` с `PyAV 18+/19.x` ([SYSTRAN/faster-whisper#1589](https://github.com/SYSTRAN/faster-whisper/issues/1589)) и квадратичного зависания `collect_chunks` на длинных видео ([SYSTRAN/faster-whisper#1690](https://github.com/SYSTRAN/faster-whisper/issues/1690)).
4. Стабильную загрузку весов в условиях фильтрации CDN (`https://hf-mirror.com` с фоллбэком на `https://huggingface.co` и поддержкой оффлайн-папки `./models/`).
5. Поддержку как выбора файлов через диалоговое окно `tkinter`, так и прямого перетаскивания файлов (Drag-and-Drop) на иконку `.bat` или передачи путей через CLI.

---

## 2. Аудит ошибок отчёта Gemini 3.8 Flash и их исправление

| Проблема | Что предлагала Gemini 3.8 Flash | Почему это не работало в ноябре 2026 | Как исправлено в релизе v4 Argon |
| :--- | :--- | :--- | :--- |
| **1. Причина кракозябр при распаковке `translate_v4_argon.py`** | Декодировать сломанный `.py` вручную и оставить в `Install Whisper.bat` старую строку `Get-Content '%~f0' -Raw` + `[Text.Encoding]::UTF8`. | В Windows PowerShell 5.1 `Get-Content` без `-Encoding UTF8` читает файл без BOM в системной кодировке ANSI (`Windows-1251`), а `[Text.Encoding]::UTF8` пишет UTF-8 с BOM. Любой повторный запуск `Install Whisper.bat` снова ломал кодировку `translate_v4_argon.py`. Кроме того, ленивая регулярка `.*?#---PYTHON_CODE_START---#` рисковала сработать на самой строке PowerShell. | Чтение переведено на `[IO.File]::ReadAllText($env:BAT_SELF, [Text.Encoding]::UTF8)`, поиск маркера — через `$raw.LastIndexOf('#' + '---PYTHON_CODE_START---#')`, запись — строго через `New-Object System.Text.UTF8Encoding($false)` (UTF-8 без BOM). |
| **2. Падение `faster-whisper 1.2.1` на `PyAV 19.x` (`metadata_errors`)** | Считала это проблемой только Python 3.15 и предлагала на Python 3.14 ставить штатный `pip install faster-whisper`, а на 3.15 вообще не ставить `av`. | В `faster-whisper 1.2.1` зависимость указана как `av>=11` без верхней границы. На **Python 3.14** `pip` ставит свежий [av 19.0.2](https://pypi.org/project/av/), где удалён параметр `metadata_errors="ignore"` из `av.open()` ([Issue #1589](https://github.com/SYSTRAN/faster-whisper/issues/1589), [NousResearch/hermes-agent#135245](https://github.com/NousResearch/hermes-agent/issues/135245), [odysseus-dev/odysseus#6716](https://github.com/odysseus-dev/odysseus/issues/6716)). В итоге на Python 3.14 скрипт падал с `TypeError`. | В `translate_v4_argon.py` внедрён runtime-шим `_patched_av_open`, который проверяет сигнатуру `av.open` и удаляет `metadata_errors` / `metadata_encoding`, если установлен `PyAV >= 18`. |
| **3. Установка и импорт `av` (PyAV) на Python 3.15** | Не ставить `av` на Python 3.15 (`--no-deps faster-whisper`), а после импорта `WhisperModel` патчить `faster_whisper.audio.decode_audio`. | Во-первых, у [av 19.0.2](https://pypi.org/project/av/) есть официальное бинарное колесо `av-19.0.2-cp312-abi3-win_amd64.whl` (Stable ABI `abi3`), которое ставится на **Python 3.15** без компиляции и содержит встроенные FFmpeg DLL. Во-вторых, без пакета `av` строка `from faster_whisper import WhisperModel` мгновенно падает с `ModuleNotFoundError: No module named 'av'`, так как `faster_whisper/audio.py` импортирует `av` на верхнем уровне. В-третьих, патчить только `faster_whisper.audio.decode_audio` бесполезно: `faster_whisper/transcribe.py` делает `from faster_whisper.audio import decode_audio` при импорте и сохраняет старую ссылку. | На Python 3.15 устанавливается бинарное колесо `av>=19.0.2` (`cp312-abi3`). Дополнительно, если `av` отсутствует, до импорта `faster_whisper` регистрируется легковесный стаб `sys.modules["av"]`, а гибридный декодер `_hybrid_decode_audio` (PyAV + откат на `ffmpeg.exe`) привязывается сразу к трём точкам: `faster_whisper.audio.decode_audio`, `faster_whisper.transcribe.decode_audio` и `faster_whisper.decode_audio`. |
| **4. Зависимости `--no-deps faster-whisper` на Python 3.15** | В списке `pip install` для 3.15 были пропущены `tqdm`, `pyyaml`, `requests`, `filelock`, `fsspec`, `packaging`, `typing-extensions`. | `faster_whisper/transcribe.py` напрямую импортирует `tqdm`; при чистой установке без кэша отсутствие транзитивных пакетов приводило к `ModuleNotFoundError`. | В ветку Python 3.15 (`:BRANCH_315`) явно включены все необходимые колёса: [ctranslate2 >= 4.8.5](https://pypi.org/project/ctranslate2/) (`cp315-win_amd64`), [numpy >= 2.5.4](https://pypi.org/project/numpy/) (`cp315-win_amd64`), [tokenizers >= 0.23.3](https://pypi.org/project/tokenizers/) (`cp310-abi3-win_amd64`), [av >= 19.0.2](https://pypi.org/project/av/) (`cp312-abi3-win_amd64`), `huggingface-hub>=0.23`, `tqdm`, `certifi`, `pyyaml`, `requests`, `filelock`, `fsspec`, `packaging`, `typing-extensions`, `nvidia-cublas-cu12`, `nvidia-cudnn-cu12`. |
| **5. Зависание `collect_chunks` на длинных записях** | Не упоминалось в отчёте 3.8 Flash. | В `faster-whisper 1.2.1` при `vad_filter=True` и `min_silence_duration_ms=500` функция `collect_chunks` в цикле копировала массив через `np.concatenate`, создавая квадратичную сложность $O(N^2)$ — на 2.5-часовой лекции это давало ~350 ГБ записи в ОЗУ и фриз на 128 секунд ([SYSTRAN/faster-whisper#1690](https://github.com/SYSTRAN/faster-whisper/issues/1690)). | В `translate_v4_argon.py` бэкпортирован линейный $O(N)$ патч `_linear_collect_chunks` (коммит `846467d` / PR #1692), сокращающий склейку чанков со 128 сек до 0.3 сек. |
| **6. Инициализация модели при OOM-откате и недоступности зеркала** | Проверка локальной папки `./models/` предлагалась только в одном месте, без учёта OOM-фоллбэка и без таймаутов сокета. | При CUDA OOM функция `transcribe_file_with_fallback` вызывала прямой `WhisperModel(...)`, игнорируя `./models/`, а при недоступности `hf-mirror.com` скрипт падал без переключения на `huggingface.co`. | Выделена единая функция `instantiate_whisper_model()` с таймаутами `HF_HUB_DOWNLOAD_TIMEOUT=30`, `HF_HUB_ETAG_TIMEOUT=15`, приоритетом локальных весов `./models/<model_name>` и автоматическим фоллбэком `https://hf-mirror.com` -> `https://huggingface.co`. |

---

## 3. Детализация изменений по файлам

### 3.1. `Install Whisper.bat` и ярлыки `Install Whisper (Python 3.14 / 3.15).bat`
* **Кодовая страница и переменные среды:** первыми строками (до любых кириллических символов) выставляются `PYTHONIOENCODING=utf-8`, `PYTHONUTF8=1`, `PYYAML_FORCE_LIBYAML=0`, `HF_ENDPOINT=https://hf-mirror.com`, `HF_HUB_DISABLE_SYMLINKS_WARNING=1` и `chcp 65001 >nul`.
* **Умный обход интерпретаторов:**
  * При запуске без аргументов проверяются `python`, `py -3.14` и `py -3.15`.
  * Через нормализованный путь `sys.executable` (`SEEN_EXES`) исключается повторная установка в один и тот же интерпретатор, если `python` и `py -3.14` указывают на один бинарник.
  * Если одновременно установлены Python 3.14 и Python 3.15, установщик автоматически настраивает **оба** окружения по очереди.
  * При вызове `Install Whisper (Python 3.14).bat` или `Install Whisper (Python 3.15).bat`, если нужная версия ещё не установлена, но присутствует [Python Install Manager 26.4](https://www.python.org/downloads/release/pymanager-264/) (`py`), автоматически выполняется `py install 3.14` или `py install 3.15`.
* **Безопасная распаковка `translate_v4_argon.py`:** код после маркера `#---PYTHON_CODE_START---#` извлекается через `.NET` метод `[IO.File]::ReadAllText` в UTF-8 и сохраняется без BOM.

### 3.2. `Run Whisper.bat` и ярлыки `Run Whisper (Python 3.14 / 3.15).bat`
* Поддерживают как запуск двойным кликом (открывается GUI-диалог выбора файлов), так и перетаскивание видео/аудиофайлов мышкой на батник (Drag-and-Drop) либо вызов из командной строки с путями к файлам.
* Флаг `--py 3.14` / `--py 3.15` корректно отделяет выбор версии интерпретатора от списка переданных медиафайлов.

### 3.3. `translate_v4_argon.py`
* Полностью очищен от двойной перекодировки и сохранён в `UTF-8 without BOM`.
* Добавлена диагностическая строка старта: выводит точную версию Python, активный аудио-декодер (`PyAV (av)` или `ffmpeg.exe`) и статус фильтра тишины (`Silero VAD / onnxruntime` согласно [onnxruntime 1.31.1](https://pypi.org/project/onnxruntime/) и [microsoft/onnxruntime#33271](https://github.com/microsoft/onnxruntime/issues/33271)).
* Добавлена корректная очистка окна `root.destroy()` после закрытия диалога `filedialog.askopenfilenames` и поддержка `sys.argv[1:]`.
* При ошибке `onnxruntime` во время выполнения (например, повреждённая DLL на нестандартной сборке Windows) скрипт автоматически откатывает указатель записи файла (`seek`/`truncate`), отключает `vad_filter` и продолжает расшифровку без потери данных.
* Встроены `.gitignore` и `.gitattributes` в корне репозитория для принудительного сохранения `CRLF` у `.bat` файлов и `LF` у `.py`/`.md` при любых операциях с Git.
