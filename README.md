# IvoryWhisperAIScript (Ноябрь 2026)

Пакетная расшифровка видео и аудио на базе `faster-whisper` (`large-v3-turbo`) и `CTranslate2 4.8.5+` с оптимизацией под 4 ГБ VRAM (NVIDIA GeForce GTX 1650 Ti, CUDA 12 + cuDNN 9) и полной совместимостью как с **Python 3.14.x**, так и с **Python 3.15.x** (выпущен в октябре 2026).

---

## Состав репозитория

| Файл | Назначение |
| :--- | :--- |
| `Install Whisper.bat` | Универсальный установщик: автоматически настраивает все найденные среды (`python`, `py -3.14`, `py -3.15`) и распаковывает `translate_v4_argon.py` в чистом UTF-8 без BOM |
| `Run Whisper.bat` | Универсальный запуск расшифровки |
| `Install Whisper (Python 3.14).bat` | Принудительная установка под **Python 3.14** (`py -3.14`, при отсутствии доустанавливает через `py install 3.14`) |
| `Run Whisper (Python 3.14).bat` | Принудительный запуск под **Python 3.14** |
| `Install Whisper (Python 3.15).bat` | Принудительная установка под **Python 3.15** (`py -3.15`, при отсутствии доустанавливает через `py install 3.15`) |
| `Run Whisper (Python 3.15).bat` | Принудительный запуск под **Python 3.15** |
| `translate_v4_argon.py` | Основной скрипт транскрибации с автоопределением GPU/VRAM, патчами совместимости Python 3.14/3.15 и откатом при OOM |
| `Whisper_AI_Technical_Report_2026-gemini-3.8FH.md` | Исходный технический отчёт (сохранён для истории) |

---

## Что исправлено (включая ошибки исходного отчёта Gemini 3.8 Flash)

1. **Кодировка UTF-8 и причина кракозябр в `Install Whisper.bat`**:
   * В исходном `Install Whisper.bat` команда `Get-Content '%~f0' -Raw` в Windows PowerShell 5.1 без параметра `-Encoding UTF8` читала UTF-8 батник в системной кодировке ANSI (`Windows-1251`), а `[Text.Encoding]::UTF8` записывал результат с BOM и двойным перекодированием (`Р’С‹Р±РµСЂРёС‚Рµ`).
   * Исправлено на `Get-Content -LiteralPath '%~f0' -Raw -Encoding UTF8` и `New-Object System.Text.UTF8Encoding($false)` (UTF-8 без BOM).
   * В батниках и `translate_v4_argon.py` выставлены `PYTHONIOENCODING=utf-8`, `PYTHONUTF8=1`, `chcp 65001 >nul` и `sys.stdout.reconfigure(encoding="utf-8")`.

2. **Критическая ошибка отчёта 3.8 Flash с `PyAV 19.x` (`metadata_errors`) на Python 3.14 и 3.15**:
   * **В чём ошибся 3.8 Flash**: в отчёте утверждалось, что на Python 3.14 штатный `pip install faster-whisper` работает без изменений, а на Python 3.15 нужно отказаться от `av` и требовать внешний `ffmpeg.exe`.
   * **Реальность (ноябрь 2026)**:
     * `faster-whisper 1.2.1` (последний релиз на PyPI) требует `av>=11` без верхней границы, поэтому `pip` ставит `av 19.0.2` и на Python 3.14, и на Python 3.15. В `PyAV >= 18.0` удалён аргумент `metadata_errors="ignore"` из `av.open()` ([SYSTRAN/faster-whisper#1589](https://github.com/SYSTRAN/faster-whisper/issues/1589)), из-за чего непатченный `faster-whisper 1.2.1` падает с `TypeError` даже на Python 3.14.
     * Пакет `av 19.0.2` публикует на PyPI колесо `av-19.0.2-cp312-abi3-win_amd64.whl` (Stable ABI `abi3`), которое ставится на **Python 3.15** без компиляции и уже содержит встроенные DLL библиотеки FFmpeg.
     * Если не поставить `av` на Python 3.15 (как советовал 3.8 Flash), `from faster_whisper import WhisperModel` падает на старте с `ModuleNotFoundError: No module named 'av'` внутри `faster_whisper/audio.py`. Кроме того, патчить только `faster_whisper.audio.decode_audio` бесполезно, так как `faster_whisper/transcribe.py` делает прямой импорт `from faster_whisper.audio import decode_audio`.
   * **Наше решение**:
     * На обеих версиях (3.14 и 3.15) ставится бинарное колесо `av>=19.0.2` (`cp312-abi3`).
     * В `translate_v4_argon.py` добавлен runtime-шим `_patched_av_open`, автоматически удаляющий неподдерживаемые `metadata_errors` / `metadata_encoding` перед вызовом `av.open`.
     * Если `av` не установлен в кастомном окружении, создаётся `sys.modules["av"]` заглушка до импорта `faster_whisper`, а `decode_audio` переопределяется сразу в трёх пространствах (`faster_whisper.audio`, `faster_whisper.transcribe`, `faster_whisper`) с автоматическим откатом на системный/портативный `ffmpeg.exe`.

3. **Поддержка Python 3.15 (`CTranslate2 4.8.5` + обход отсутствующего `onnxruntime`)**:
   * `ctranslate2 4.8.5` (от 02.11.2026) имеет официальное колесо `cp315-cp315-win_amd64.whl`.
   * У `onnxruntime 1.31.1` (от 26.10.2026) есть `cp314-win_amd64.whl`, но ещё нет `cp315` ([microsoft/onnxruntime#33271](https://github.com/microsoft/onnxruntime/issues/33271)).
   * На Python 3.15 батник устанавливает все бинарные зависимости напрямую (`ctranslate2>=4.8.5`, `av>=19.0.2`, `numpy>=2.5.4`, `tokenizers>=0.23.3`, `huggingface-hub>=0.23`, `tqdm`, `certifi`, `pyyaml`, `requests`, `nvidia-cublas-cu12`, `nvidia-cudnn-cu12`) и ставит `faster-whisper` с флагом `--no-deps`.
   * В `translate_v4_argon.py` доступность `onnxruntime` проверяется динамически (`is_vad_available()`): на Python 3.14 активен `vad_filter=True` (Silero VAD), на Python 3.15 автоматически выставляется `vad_filter=False`.

4. **Устранение квадратичного зависания `collect_chunks` на длинных видео ([SYSTRAN/faster-whisper#1690](https://github.com/SYSTRAN/faster-whisper/issues/1690))**:
   * В `faster-whisper 1.2.1` при `vad_filter=True` и `min_silence_duration_ms=500` функция `collect_chunks` в цикле пересоздавала массив через `np.concatenate`, вызывая до 350 ГБ записи в ОЗУ и зависание на 2+ минуты перед началом транскрибации.
   * В `translate_v4_argon.py` встроен линейный $O(N)$ патч `_linear_collect_chunks` (бэкпорт коммита `846467d` / PR #1692 от ноября 2026).

5. **Обход блокировок CDN Hugging Face и оффлайн-режим**:
   * Выставлены `HF_ENDPOINT=https://hf-mirror.com` и неблокирующие таймауты сокетов (`HF_HUB_DOWNLOAD_TIMEOUT=30`, `HF_HUB_ETAG_TIMEOUT=15`).
   * Если зеркало `hf-mirror.com` недоступно, `instantiate_whisper_model()` автоматически переключается на `https://huggingface.co`.
   * При наличии локальной папки `./models/large-v3-turbo` (или `./models/turbo`, `./models/medium`) с файлом `model.bin` загрузка выполняется полностью оффлайн (`local_files_only=True`).
