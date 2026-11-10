import gc
import inspect
import os
import shutil
import site
import subprocess
import sys
import time
import types
import tkinter as tk
from tkinter import filedialog

# --- 0. ПРИНУДИТЕЛЬНАЯ РЕКОНФИГУРАЦИЯ ПОТОКОВ ВВОДА-ВЫВОДА В UTF-8 ---
os.environ.setdefault("PYTHONIOENCODING", "utf-8")
os.environ.setdefault("PYTHONUTF8", "1")
for _stream_name in ("stdout", "stderr"):
    _stream = getattr(sys, _stream_name, None)
    if _stream is not None and hasattr(_stream, "reconfigure"):
        try:
            _stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

# --- 1. ПОИСК И ПОДКЛЮЧЕНИЕ БИБЛИОТЕК NVIDIA (CUDA 12 + cuDNN 9) ---
_DLL_HANDLES = []


def setup_nvidia_dlls() -> tuple[bool, bool]:
    """Ищет cublas64_12.dll и cudnn64_9.dll в site-packages и системном PATH."""
    found_cublas = False
    found_cudnn = False

    search_paths = list(sys.path)
    for getter in (site.getsitepackages, lambda: [site.getusersitepackages()]):
        try:
            search_paths.extend(getter())
        except Exception:
            pass

    seen_bins = set()
    for path in set(search_paths):
        if not isinstance(path, str) or not os.path.isdir(path):
            continue

        # Проверяем пакеты nvidia/* и ctranslate2/
        for subdir in ("nvidia", "ctranslate2"):
            base = os.path.join(path, subdir)
            if not os.path.isdir(base):
                continue
            for root_dir, _dirs, files in os.walk(base):
                files_lower = {f.lower() for f in files}
                has_target = False
                if "cublas64_12.dll" in files_lower:
                    found_cublas = True
                    has_target = True
                if "cudnn64_9.dll" in files_lower:
                    found_cudnn = True
                    has_target = True

                if has_target or os.path.basename(root_dir).lower() == "bin":
                    norm_dir = os.path.normcase(os.path.abspath(root_dir))
                    if norm_dir not in seen_bins:
                        seen_bins.add(norm_dir)
                        os.environ["PATH"] = root_dir + os.pathsep + os.environ.get("PATH", "")
                        if hasattr(os, "add_dll_directory"):
                            try:
                                _DLL_HANDLES.append(os.add_dll_directory(root_dir))
                            except Exception:
                                pass

    # Также проверяем системный PATH / установленный CUDA Toolkit
    for dll_name, flag_name in (("cublas64_12.dll", "cublas"), ("cudnn64_9.dll", "cudnn")):
        for dir_entry in os.environ.get("PATH", "").split(os.pathsep):
            if dir_entry and os.path.isfile(os.path.join(dir_entry, dll_name)):
                if flag_name == "cublas":
                    found_cublas = True
                else:
                    found_cudnn = True
                break

    return found_cublas, found_cudnn


has_cublas, has_cudnn = setup_nvidia_dlls()

# --- 2. ИСПРАВЛЕНИЕ SSL, ТАЙМАУТОВ HUGGING FACE И ЗЕРКАЛА ---
os.environ["HF_HUB_DISABLE_SYMLINKS_WARNING"] = "1"
os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")
os.environ.setdefault("HF_HUB_DOWNLOAD_TIMEOUT", "30")
os.environ.setdefault("HF_HUB_ETAG_TIMEOUT", "15")

try:
    import certifi
    os.environ["SSL_CERT_FILE"] = certifi.where()
    os.environ["REQUESTS_CA_BUNDLE"] = certifi.where()
except ImportError:
    os.environ.pop("SSL_CERT_FILE", None)
    os.environ.pop("REQUESTS_CA_BUNDLE", None)

# --- 3. СОВМЕСТИМОСТЬ С PYTHON 3.14 / 3.15 (PyAV 18/19+, FFmpeg, ONNX, VAD) ---
import numpy as np

HAS_PYAV = False
try:
    import av  # type: ignore

    HAS_PYAV = True
    _orig_av_open = av.open

    try:
        _av_open_params = inspect.signature(_orig_av_open).parameters
        _supports_metadata_errors = (
            "metadata_errors" in _av_open_params
            or any(p.kind == inspect.Parameter.VAR_KEYWORD for p in _av_open_params.values())
        )
    except Exception:
        _supports_metadata_errors = False

    def _patched_av_open(*args, **kwargs):
        """Совместимость faster-whisper <=1.2.1 с PyAV 18+/19+ (удален metadata_errors, Issue #1589)."""
        if not _supports_metadata_errors:
            kwargs.pop("metadata_errors", None)
            kwargs.pop("metadata_encoding", None)
        try:
            return _orig_av_open(*args, **kwargs)
        except TypeError as exc:
            if "metadata_errors" in str(exc) or "metadata_encoding" in str(exc):
                kwargs.pop("metadata_errors", None)
                kwargs.pop("metadata_encoding", None)
                return _orig_av_open(*args, **kwargs)
            raise

    av.open = _patched_av_open
except ImportError:
    # Если PyAV не установлен (например, минимальная среда Python 3.15),
    # создаем легковесную заглушку, чтобы импорт faster_whisper.audio не падал.
    _av_stub = types.ModuleType("av")
    _av_stub.open = None  # type: ignore[attr-defined]
    sys.modules["av"] = _av_stub


def _find_ffmpeg_exe() -> str | None:
    """Ищет ffmpeg.exe в папке скрипта, ./ffmpeg/bin или системном PATH."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    local_candidates = (
        os.path.join(script_dir, "ffmpeg.exe"),
        os.path.join(script_dir, "bin", "ffmpeg.exe"),
        os.path.join(script_dir, "ffmpeg", "bin", "ffmpeg.exe"),
    )
    for candidate in local_candidates:
        if os.path.isfile(candidate):
            return candidate
    return shutil.which("ffmpeg")


def decode_audio_ffmpeg(
    input_file: str,
    sampling_rate: int = 16000,
    split_stereo: bool = False,
):
    """Декодирует аудио через системный/портативный ffmpeg.exe в float32 NumPy массив."""
    ffmpeg_bin = _find_ffmpeg_exe()
    if not ffmpeg_bin:
        raise RuntimeError(
            "Для декодирования аудио без пакета 'av' (PyAV) требуется ffmpeg.exe в PATH "
            "или рядом со скриптом. Либо установите PyAV: py -m pip install \"av>=19.0.2\""
        )

    channels = 2 if split_stereo else 1
    cmd = [
        ffmpeg_bin,
        "-nostdin",
        "-threads",
        "0",
        "-i",
        str(input_file),
        "-f",
        "s16le",
        "-ac",
        str(channels),
        "-acodec",
        "pcm_s16le",
        "-ar",
        str(sampling_rate),
        "-",
    ]
    creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    proc = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        creationflags=creationflags,
        check=False,
    )
    if proc.returncode != 0:
        err_text = proc.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"Ошибка декодирования через ffmpeg (код {proc.returncode}): {err_text}")

    audio = np.frombuffer(proc.stdout, dtype=np.int16).astype(np.float32) / 32768.0
    if split_stereo:
        audio = audio.reshape(-1, 2)
        return audio[:, 0], audio[:, 1]
    return audio


import ctranslate2
import faster_whisper
import faster_whisper.audio
import faster_whisper.transcribe
import faster_whisper.vad
from faster_whisper import WhisperModel

_orig_fw_decode_audio = faster_whisper.audio.decode_audio


def _hybrid_decode_audio(
    input_file,
    sampling_rate: int = 16000,
    split_stereo: bool = False,
):
    """Использует пропатченный PyAV (включая cp312-abi3 на Python 3.14/3.15) с откатом на ffmpeg.exe."""
    if isinstance(input_file, np.ndarray):
        return input_file
    if HAS_PYAV:
        try:
            return _orig_fw_decode_audio(
                input_file,
                sampling_rate=sampling_rate,
                split_stereo=split_stereo,
            )
        except Exception as pyav_exc:
            if isinstance(input_file, (str, os.PathLike)) and _find_ffmpeg_exe():
                print(f"[!] PyAV сбой ({pyav_exc}), переключение на системный ffmpeg...")
                return decode_audio_ffmpeg(
                    str(input_file),
                    sampling_rate=sampling_rate,
                    split_stereo=split_stereo,
                )
            raise
    if isinstance(input_file, (str, os.PathLike)):
        return decode_audio_ffmpeg(
            str(input_file),
            sampling_rate=sampling_rate,
            split_stereo=split_stereo,
        )
    raise RuntimeError("Пакет 'av' (PyAV) не установлен, а входные данные не являются путем к файлу.")


# Переопределяем decode_audio во всех модулях faster_whisper (в transcribe.py он импортирован напрямую)
faster_whisper.audio.decode_audio = _hybrid_decode_audio
faster_whisper.transcribe.decode_audio = _hybrid_decode_audio
faster_whisper.decode_audio = _hybrid_decode_audio


def _linear_collect_chunks(
    audio: np.ndarray,
    chunks: list[dict],
    sampling_rate: int = 16000,
    max_duration: float = float("inf"),
):
    """Линейный O(N) патч collect_chunks (фикс SYSTRAN/faster-whisper#1690 / PR #1692)."""
    if not chunks:
        chunk_metadata = {
            "offset": 0,
            "duration": 0,
            "segments": [],
        }
        return [np.array([], dtype=np.float32)], [chunk_metadata]

    audio_chunks = []
    chunks_metadata = []
    current_segments = []
    current_duration = 0
    total_duration = 0
    current_slices = [np.array([], dtype=np.float32)]

    for chunk in chunks:
        if chunk["end"] - chunk["start"] > max_duration * sampling_rate:
            raise ValueError(
                f"Chunk starting at {chunk['start'] / sampling_rate:.2f}s "
                f"has duration {(chunk['end'] - chunk['start']) / sampling_rate:.2f}s, "
                f"which is greater than max_duration {max_duration:.2f}s."
            )

        if current_duration + chunk["end"] - chunk["start"] > max_duration * sampling_rate:
            audio_chunks.append(np.concatenate(current_slices))
            chunk_metadata = {
                "offset": total_duration / sampling_rate,
                "duration": current_duration / sampling_rate,
                "segments": current_segments,
            }
            total_duration += current_duration
            chunks_metadata.append(chunk_metadata)

            current_segments = [chunk]
            current_slices = [audio[chunk["start"] : chunk["end"]]]
            current_duration = chunk["end"] - chunk["start"]
        else:
            current_segments.append(chunk)
            current_slices.append(audio[chunk["start"] : chunk["end"]])
            current_duration += chunk["end"] - chunk["start"]

    audio_chunks.append(np.concatenate(current_slices))
    chunk_metadata = {
        "offset": total_duration / sampling_rate,
        "duration": current_duration / sampling_rate,
        "segments": current_segments,
    }
    chunks_metadata.append(chunk_metadata)
    return audio_chunks, chunks_metadata


try:
    _cc_params = inspect.signature(faster_whisper.vad.collect_chunks).parameters
    if "max_duration" in _cc_params:
        faster_whisper.vad.collect_chunks = _linear_collect_chunks
        faster_whisper.transcribe.collect_chunks = _linear_collect_chunks
except Exception:
    pass


def is_vad_available() -> bool:
    """Проверяет доступность onnxruntime для работы Silero VAD (отсутствует на Python 3.15 в ноябре 2026)."""
    try:
        import onnxruntime  # noqa: F401
        return True
    except Exception:
        return False


HAS_ONNXRUNTIME = is_vad_available()
# ------------------------------------------------------------------------------


def get_gpu_info() -> str:
    """Динамически определяет название GPU и объем VRAM через nvidia-smi."""
    smi = shutil.which("nvidia-smi")
    if not smi:
        default_smi = os.path.join(
            os.environ.get("SystemRoot", r"C:\Windows"),
            "System32",
            "nvidia-smi.exe",
        )
        if os.path.isfile(default_smi):
            smi = default_smi

    if smi:
        try:
            creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
            out = subprocess.check_output(
                [smi, "--query-gpu=name,memory.total", "--format=csv,noheader,nounits"],
                encoding="utf-8",
                errors="replace",
                timeout=3,
                creationflags=creationflags,
            ).strip()
            if out:
                first_line = out.splitlines()[0]
                parts = [p.strip() for p in first_line.split(",")]
                if len(parts) >= 2:
                    return f"{parts[0]} ({parts[1]} МБ VRAM)"
                return parts[0]
        except Exception:
            pass
    return "NVIDIA CUDA GPU"


def format_timestamp(seconds: float) -> str:
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    secs = int(seconds % 60)
    return f"{hours:02d}:{minutes:02d}:{secs:02d}"


def resolve_local_model_dir(model_name: str) -> str | None:
    """Проверяет наличие оффлайн-модели в папке ./models/<model_name>."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    candidates = [os.path.join(script_dir, "models", model_name)]
    if model_name == "large-v3-turbo":
        candidates.append(os.path.join(script_dir, "models", "turbo"))
        candidates.append(os.path.join(script_dir, "models", "faster-whisper-large-v3-turbo"))
    for folder in candidates:
        if os.path.isdir(folder) and os.path.isfile(os.path.join(folder, "model.bin")):
            return folder
    return None


def instantiate_whisper_model(
    model_name: str,
    device: str,
    compute_type: str,
    cpu_threads: int = 4,
) -> WhisperModel:
    """Создает экземпляр WhisperModel с приоритетом локальной папки ./models и зеркала HF."""
    local_dir = resolve_local_model_dir(model_name)
    if local_dir:
        print(f"[*] Используется локальная модель из папки: {local_dir}")
        return WhisperModel(
            local_dir,
            device=device,
            compute_type=compute_type,
            cpu_threads=cpu_threads,
            local_files_only=True,
        )

    # Попытка загрузки через текущее зеркало (по умолчанию https://hf-mirror.com)
    try:
        return WhisperModel(
            model_name,
            device=device,
            compute_type=compute_type,
            cpu_threads=cpu_threads,
        )
    except Exception as primary_exc:
        # Если зеркало недоступно, пробуем прямое подключение к huggingface.co
        current_endpoint = os.environ.get("HF_ENDPOINT", "")
        if "hf-mirror.com" in current_endpoint:
            print(f"[!] Зеркало {current_endpoint} недоступно ({primary_exc}), повтор через huggingface.co...")
            os.environ["HF_ENDPOINT"] = "https://huggingface.co"
            return WhisperModel(
                model_name,
                device=device,
                compute_type=compute_type,
                cpu_threads=cpu_threads,
            )
        raise


def load_whisper_model(model_size: str = "large-v3-turbo") -> tuple[WhisperModel, str]:
    """Загружает модель с квантованием под 4 ГБ VRAM (GTX 1650 Ti) и резервным откатом."""
    py_ver = f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}"
    audio_backend = "PyAV (av)" if HAS_PYAV else ("ffmpeg.exe" if _find_ffmpeg_exe() else "не найден")
    vad_status = "Включен (Silero VAD / onnxruntime)" if HAS_ONNXRUNTIME else "Отключен (нет onnxruntime для этой версии Python)"
    print(f"[*] Среда: Python {py_ver} | Аудио-декодер: {audio_backend} | VAD: {vad_status}")

    cuda_available = False
    try:
        cuda_available = ctranslate2.get_cuda_device_count() > 0
    except Exception:
        cuda_available = False

    if cuda_available and has_cublas:
        if not has_cudnn:
            print(
                "[!] Предупреждение: cudnn64_9.dll не найдена в путях. "
                "При ошибке запуска выполните: py -m pip install nvidia-cudnn-cu12"
            )

        gpu_label = get_gpu_info()
        # int8_float16: ~1.5 ГБ VRAM на Turing (CC 7.5).
        # При баге FP16 на конкретной версии cuDNN на GTX 1650 Ti можно сменить на "int8_float32".
        for candidate_model, compute_type in (
            (model_size, "int8_float16"),
            (model_size, "int8_float32"),
            ("medium", "int8_float16"),
        ):
            try:
                print(f"\n[*] Запуск '{candidate_model}' на {gpu_label} (CUDA {compute_type})...")
                model = instantiate_whisper_model(
                    candidate_model,
                    device="cuda",
                    compute_type=compute_type,
                    cpu_threads=4,
                )
                return model, candidate_model
            except Exception as exc:
                print(f"[!] Не удалось загрузить '{candidate_model}' ({compute_type}) на GPU: {exc}")

    else:
        missing = []
        if not has_cublas:
            missing.append("nvidia-cublas-cu12 (cublas64_12.dll)")
        if not has_cudnn:
            missing.append("nvidia-cudnn-cu12 (cudnn64_9.dll)")
        if missing:
            print(
                f"\n[!] Не найдены CUDA-библиотеки: {', '.join(missing)}.\n"
                "    Для GPU-ускорения выполните: py -m pip install nvidia-cublas-cu12 nvidia-cudnn-cu12"
            )

    print(f"\n[*] Запуск '{model_size}' на процессоре (CPU int8)...")
    return instantiate_whisper_model(model_size, device="cpu", compute_type="int8"), model_size


def release_whisper_vram(model: WhisperModel) -> None:
    """Принудительно освобождает C++ буферы CTranslate2 в VRAM даже при живой внешней ссылке."""
    try:
        if hasattr(model, "model"):
            del model.model
    except Exception:
        pass
    gc.collect()


def transcribe_file_with_fallback(
    model: WhisperModel,
    model_size: str,
    video_path: str,
    f_txt,
    f_timed,
) -> tuple[WhisperModel, str]:
    """Транскрибирует файл; при CUDA OOM откатывает частичную запись и переключается на резерв."""
    use_vad = HAS_ONNXRUNTIME
    transcribe_kwargs = dict(
        beam_size=1,
        best_of=1,
        condition_on_previous_text=False,
        vad_filter=use_vad,
    )
    if use_vad:
        transcribe_kwargs["vad_parameters"] = dict(min_silence_duration_ms=500)

    f_txt.flush()
    f_timed.flush()
    txt_pos = f_txt.tell()
    timed_pos = f_timed.tell()

    for attempt in range(2):
        try:
            segments, _info = model.transcribe(video_path, **transcribe_kwargs)
            for segment in segments:
                start_ts = format_timestamp(segment.start)
                end_ts = format_timestamp(segment.end)
                clean_text = segment.text.strip()

                line_with_time = f"[{start_ts} -> {end_ts}] {clean_text}"
                print(line_with_time)

                f_txt.write(clean_text + " ")
                f_timed.write(line_with_time + "\n")

                f_txt.flush()
                f_timed.flush()
            return model, model_size

        except RuntimeError as exc:
            err_msg = str(exc).lower()
            if "onnxruntime" in err_msg and transcribe_kwargs.get("vad_filter"):
                print("[!] Пакет onnxruntime недоступен во время выполнения. Отключаем vad_filter и повторяем...")
                transcribe_kwargs["vad_filter"] = False
                transcribe_kwargs.pop("vad_parameters", None)
                f_txt.seek(txt_pos)
                f_txt.truncate()
                f_timed.seek(timed_pos)
                f_timed.truncate()
                segments, _info = model.transcribe(video_path, **transcribe_kwargs)
                for segment in segments:
                    start_ts = format_timestamp(segment.start)
                    end_ts = format_timestamp(segment.end)
                    clean_text = segment.text.strip()
                    line_with_time = f"[{start_ts} -> {end_ts}] {clean_text}"
                    print(line_with_time)
                    f_txt.write(clean_text + " ")
                    f_timed.write(line_with_time + "\n")
                    f_txt.flush()
                    f_timed.flush()
                return model, model_size

            if attempt == 0 and any(k in err_msg for k in ("out of memory", "cuda", "cublas", "cudnn")):
                print(f"\n[!] Ошибка GPU во время декодирования ({exc}). Откат частичной записи файла...")
                f_txt.seek(txt_pos)
                f_txt.truncate()
                f_timed.seek(timed_pos)
                f_timed.truncate()

                release_whisper_vram(model)
                del model

                fallback_name = "medium" if model_size != "medium" else model_size
                try:
                    if fallback_name != model_size:
                        print(f"[*] Переключение на резервную модель '{fallback_name}' (CUDA int8_float16)...")
                        model = instantiate_whisper_model(
                            fallback_name,
                            device="cuda",
                            compute_type="int8_float16",
                        )
                        model_size = fallback_name
                        continue
                except Exception:
                    pass
                print(f"[*] Аварийное переключение '{model_size}' на процессор (CPU int8)...")
                model = instantiate_whisper_model(model_size, device="cpu", compute_type="int8")
                continue
            raise

    return model, model_size


def select_and_transcribe():
    root = tk.Tk()
    root.withdraw()
    root.attributes("-topmost", True)

    print("[*] Выберите ОДНО или НЕСКОЛЬКО видео в появившемся окне (через Ctrl или Shift)...")
    video_paths = filedialog.askopenfilenames(
        title="Выберите видеофайлы для расшифровки и объединения",
        filetypes=[
            ("Видео и Аудио", "*.mp4 *.mkv *.avi *.mov *.mp3 *.wav *.m4a *.webm *.flac *.ogg"),
            ("Все файлы", "*.*"),
        ],
    )

    if not video_paths:
        print("[!] Файлы не выбраны. Завершение работы.")
        return

    video_paths = sorted(list(video_paths))
    total_files = len(video_paths)

    print(f"[+] Выбрано файлов: {total_files}")
    for i, path in enumerate(video_paths, 1):
        print(f"    {i}. {os.path.basename(path)}")

    model, active_model_size = load_whisper_model("large-v3-turbo")

    folder = os.path.dirname(video_paths[0])
    if total_files == 1:
        base_name = os.path.splitext(video_paths[0])[0]
        txt_output = f"{base_name}_text.txt"
        timed_output = f"{base_name}_timestamps.txt"
    else:
        txt_output = os.path.join(folder, "Общая_расшифровка_текст.txt")
        timed_output = os.path.join(folder, "Общая_расшифровка_таймкоды.txt")

    total_start_time = time.time()

    with open(txt_output, "w", encoding="utf-8") as f_txt, \
         open(timed_output, "w", encoding="utf-8") as f_timed:

        for idx, video_path in enumerate(video_paths, 1):
            file_name = os.path.basename(video_path)
            print("\n" + "=" * 60)
            print(f"[*] [{idx}/{total_files}] Расшифровка: {file_name}")
            print("=" * 60)

            header = (
                f"\n\n==================== {file_name} ====================\n\n"
                if idx > 1
                else f"==================== {file_name} ====================\n\n"
            )
            f_txt.write(header)
            f_timed.write(header)

            model, active_model_size = transcribe_file_with_fallback(
                model, active_model_size, video_path, f_txt, f_timed
            )

    print("\n" + "-" * 60)
    print(f"[✓] Все файлы ({total_files} шт.) успешно обработаны за {time.time() - total_start_time:.2f} сек!")
    print(f"[✓] Единый чистый текст: {txt_output}")
    print(f"[✓] Единый файл с таймкодами: {timed_output}")


if __name__ == "__main__":
    select_and_transcribe()
