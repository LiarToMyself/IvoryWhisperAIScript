@echo off
setlocal EnableExtensions
cd /d "%~dp0"
set "PYTHONIOENCODING=utf-8"
set "PYTHONUTF8=1"
set "HF_HUB_DISABLE_SYMLINKS_WARNING=1"
set "HF_HUB_DISABLE_XET=1"
set "HF_HUB_ENABLE_HF_TRANSFER=0"
chcp 65001 >nul
title Запуск расшифровки видео [Whisper AI]
color 0F

:: Автоматически обновляем translate_v4_argon.py (с встроенным докачивателем моделей и прогресс-баром)
set "RUN_SELF=%~f0"
set "OUT_PY=%~dp0translate_v4_argon.py"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$raw = [IO.File]::ReadAllText($env:RUN_SELF, [Text.Encoding]::UTF8); $m = '#' + '---PYTHON_CODE_START---#'; $idx = $raw.LastIndexOf($m); if ($idx -ge 0) { $code = $raw.Substring($idx + $m.Length).TrimStart(\"`r\", \"`n\"); [IO.File]::WriteAllText($env:OUT_PY, $code, (New-Object System.Text.UTF8Encoding($false))) }" >nul 2>&1

if not exist "translate_v4_argon.py" (
    color 0C
    echo [!] ОШИБКА: Файл translate_v4_argon.py не найден!
    echo [*] Сначала запустите файл "Install Whisper.bat".
    echo.
    pause
    exit /b 1
)

set "REQ_PY="
if "%~1"=="--py" (
    set "REQ_PY=%~2"
    shift
    shift
    goto :HANDLE_REQ_PY
)
if "%~1"=="3.14" if not exist "%~1" (
    set "REQ_PY=3.14"
    shift
    goto :HANDLE_REQ_PY
)
if "%~1"=="3.15" if not exist "%~1" (
    set "REQ_PY=3.15"
    shift
    goto :HANDLE_REQ_PY
)

set "PY_CMD="
python --version >nul 2>&1
if not errorlevel 1 (
    set "PY_CMD=python"
    goto :RUN_NOW
)

py -3.14 --version >nul 2>&1
if not errorlevel 1 (
    set "PY_CMD=py -3.14"
    goto :RUN_NOW
)

py -3.15 --version >nul 2>&1
if not errorlevel 1 (
    set "PY_CMD=py -3.15"
    goto :RUN_NOW
)

py --version >nul 2>&1
if not errorlevel 1 (
    set "PY_CMD=py"
    goto :RUN_NOW
)

goto :NO_PYTHON

:HANDLE_REQ_PY
py -%REQ_PY% --version >nul 2>&1
if not errorlevel 1 (
    set "PY_CMD=py -%REQ_PY%"
    goto :RUN_NOW
)

set "SYS_VER="
for /f "delims=" %%v in ('python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2^>nul') do set "SYS_VER=%%v"
if "%SYS_VER%"=="%REQ_PY%" (
    set "PY_CMD=python"
    goto :RUN_NOW
)

color 0C
echo [!] ОШИБКА: Python %REQ_PY% не найден в системе!
echo [*] Запустите "Install Whisper.bat" для установки.
echo.
pause
exit /b 1

:NO_PYTHON
color 0C
echo [!] ОШИБКА: Интерпретатор Python не найден в системе!
pause
exit /b 1

:RUN_NOW
echo [*] Запуск скрипта расшифровки через: %PY_CMD%
echo.
%PY_CMD% "translate_v4_argon.py" %1 %2 %3 %4 %5 %6 %7 %8 %9
echo.
pause
exit /b 0

#---PYTHON_CODE_START---#
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

# --- 2. НАСТРОЙКА СКАЧИВАНИЯ HUGGING FACE (ОТКЛЮЧЕНИЕ ЗАВИСАЮЩЕГО XET НА WINDOWS) ---
os.environ["HF_HUB_DISABLE_SYMLINKS_WARNING"] = "1"
os.environ["HF_HUB_DISABLE_XET"] = "1"
os.environ["HF_HUB_ENABLE_HF_TRANSFER"] = "0"
os.environ.setdefault("HF_HUB_DOWNLOAD_TIMEOUT", "60")
os.environ.setdefault("HF_HUB_ETAG_TIMEOUT", "30")

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
    _av_stub = types.ModuleType("av")
    _av_stub.open = None  # type: ignore[attr-defined]
    sys.modules["av"] = _av_stub


def _find_ffmpeg_exe() -> str | None:
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
import faster_whisper.utils
import faster_whisper.vad
from faster_whisper import WhisperModel

try:
    import tqdm
    faster_whisper.utils.disabled_tqdm = tqdm.tqdm
except Exception:
    pass

_orig_fw_decode_audio = faster_whisper.audio.decode_audio


def _hybrid_decode_audio(
    input_file,
    sampling_rate: int = 16000,
    split_stereo: bool = False,
):
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


faster_whisper.audio.decode_audio = _hybrid_decode_audio
faster_whisper.transcribe.decode_audio = _hybrid_decode_audio
faster_whisper.decode_audio = _hybrid_decode_audio


def _linear_collect_chunks(
    audio: np.ndarray,
    chunks: list[dict],
    sampling_rate: int = 16000,
    max_duration: float = float("inf"),
):
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
    try:
        import onnxruntime  # noqa: F401
        return True
    except Exception:
        return False


HAS_ONNXRUNTIME = is_vad_available()
# ------------------------------------------------------------------------------


def get_gpu_info() -> str:
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


_MODEL_REPOS = {
    "large-v3-turbo": [
        "mobiuslabsgmbh/faster-whisper-large-v3-turbo",
        "rtlingo/mobiuslabsgmbh-faster-whisper-large-v3-turbo",
        "deepdml/faster-whisper-large-v3-turbo-ct2",
    ],
    "medium": [
        "Systran/faster-whisper-medium",
    ],
}


def resolve_local_model_dir(model_name: str) -> str | None:
    script_dir = os.path.dirname(os.path.abspath(__file__))
    candidates = [os.path.join(script_dir, "models", model_name)]
    if model_name == "large-v3-turbo":
        candidates.append(os.path.join(script_dir, "models", "turbo"))
        candidates.append(os.path.join(script_dir, "models", "faster-whisper-large-v3-turbo"))

    # Также проверяем стандартный кэш Hugging Face, если модель уже была скачана ранее
    hf_home = os.environ.get("HF_HOME") or os.path.join(os.path.expanduser("~"), ".cache", "huggingface")
    hub_dir = os.path.join(hf_home, "hub")
    for repo_id in _MODEL_REPOS.get(model_name, []):
        snap_root = os.path.join(hub_dir, "models--" + repo_id.replace("/", "--"), "snapshots")
        if os.path.isdir(snap_root):
            for sub in os.listdir(snap_root):
                candidates.append(os.path.join(snap_root, sub))

    for folder in candidates:
        bin_path = os.path.join(folder, "model.bin")
        cfg_path = os.path.join(folder, "config.json")
        if os.path.isdir(folder) and os.path.isfile(bin_path) and os.path.isfile(cfg_path):
            if os.path.getsize(bin_path) > 50_000_000:
                return folder
    return None


def _download_single_file(url: str, dest_path: str, desc: str, required: bool = True) -> bool:
    part_path = dest_path + ".part"
    existing_size = os.path.getsize(part_path) if os.path.isfile(part_path) else 0
    headers = {"User-Agent": "faster-whisper-downloader/1.0"}
    if existing_size > 0:
        headers["Range"] = f"bytes={existing_size}-"

    try:
        import requests
        from tqdm import tqdm

        resp = requests.get(url, headers=headers, stream=True, timeout=(15, 60), allow_redirects=True)
        if resp.status_code == 404 and not required:
            resp.close()
            return False
        if resp.status_code == 416:
            resp.close()
            if os.path.isfile(part_path):
                os.replace(part_path, dest_path)
            return True
        if resp.status_code not in (200, 206):
            resp.close()
            resp.raise_for_status()

        mode = "ab" if resp.status_code == 206 else "wb"
        if mode == "wb":
            existing_size = 0

        content_len = int(resp.headers.get("Content-Length", 0) or 0)
        total_size = (existing_size + content_len) if content_len > 0 else None

        with open(part_path, mode) as f_out, tqdm(
            total=total_size,
            initial=existing_size,
            unit="B",
            unit_scale=True,
            unit_divisor=1024,
            desc=f"    {desc}",
            ncols=88,
            file=sys.stdout,
        ) as bar:
            for chunk in resp.iter_content(chunk_size=1024 * 1024):
                if chunk:
                    f_out.write(chunk)
                    bar.update(len(chunk))

        os.replace(part_path, dest_path)
        return True
    except ImportError:
        import urllib.request
        import urllib.error

        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                status = getattr(resp, "status", 200)
                mode = "ab" if status == 206 else "wb"
                if mode == "wb":
                    existing_size = 0
                content_len = int(resp.headers.get("Content-Length", 0) or 0)
                total_mb = ((existing_size + content_len) / (1024 * 1024)) if content_len > 0 else 0
                downloaded = existing_size
                with open(part_path, mode) as f_out:
                    while True:
                        chunk = resp.read(1024 * 1024)
                        if not chunk:
                            break
                        f_out.write(chunk)
                        downloaded += len(chunk)
                        dl_mb = downloaded / (1024 * 1024)
                        if total_mb > 0:
                            print(f"\r    {desc}: {dl_mb:.1f} / {total_mb:.1f} МБ ({dl_mb * 100 / total_mb:.0f}%)", end="", flush=True)
                        else:
                            print(f"\r    {desc}: {dl_mb:.1f} МБ", end="", flush=True)
                print()
            os.replace(part_path, dest_path)
            return True
        except urllib.error.HTTPError as he:
            if he.code == 404 and not required:
                return False
            raise


def ensure_model_downloaded(model_name: str) -> str:
    """Скачивает CTranslate2-веса модели в ./models/<model_name> с прогресс-баром и докачкой."""
    local_dir = resolve_local_model_dir(model_name)
    if local_dir:
        return local_dir

    script_dir = os.path.dirname(os.path.abspath(__file__))
    target_dir = os.path.join(script_dir, "models", model_name)
    os.makedirs(target_dir, exist_ok=True)

    repos = _MODEL_REPOS.get(model_name)
    if not repos:
        default_repo = getattr(faster_whisper.utils, "_MODELS", {}).get(model_name, model_name)
        repos = [default_repo]

    endpoints = ["https://huggingface.co", "https://hf-mirror.com"]
    files_spec = [
        ("config.json", True),
        ("preprocessor_config.json", False),
        ("tokenizer.json", True),
        ("vocabulary.json", False),
        ("vocabulary.txt", False),
        ("model.bin", True),
    ]

    print(f"\n[*] Модель '{model_name}' еще не скачана. Загрузка в папку: {target_dir}")
    print("[*] Скачивание идет один раз (с поддержкой докачки при обрыве связи)...")

    last_err = None
    for endpoint in endpoints:
        for repo_id in repos:
            try:
                print(f"[*] Источник: {endpoint}/{repo_id}")
                for fname, is_req in files_spec:
                    final_path = os.path.join(target_dir, fname)
                    if os.path.isfile(final_path):
                        if fname != "model.bin" or os.path.getsize(final_path) > 50_000_000:
                            continue
                    url = f"{endpoint}/{repo_id}/resolve/main/{fname}"
                    _download_single_file(url, final_path, fname, required=is_req)

                resolved = resolve_local_model_dir(model_name)
                if resolved:
                    print(f"[✓] Модель '{model_name}' успешно скачана в {resolved}!")
                    return resolved
            except Exception as exc:
                last_err = exc
                print(f"[!] Сбой загрузки с {endpoint}/{repo_id}: {exc}")

    raise RuntimeError(f"Не удалось скачать модель '{model_name}': {last_err}")


def instantiate_whisper_model(
    model_name: str,
    device: str,
    compute_type: str,
    cpu_threads: int = 4,
) -> WhisperModel:
    local_dir = ensure_model_downloaded(model_name)
    return WhisperModel(
        local_dir,
        device=device,
        compute_type=compute_type,
        cpu_threads=cpu_threads,
        local_files_only=True,
    )


def load_whisper_model(model_size: str = "large-v3-turbo") -> tuple[WhisperModel, str]:
    py_ver = f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}"
    audio_backend = "PyAV (av)" if HAS_PYAV else ("ffmpeg.exe" if _find_ffmpeg_exe() else "не найден")
    vad_status = "Включен (Silero VAD / onnxruntime)" if HAS_ONNXRUNTIME else "Отключен (нет onnxruntime для этой версии Python)"
    print(f"[*] Среда: Python {py_ver} | Аудио-декодер: {audio_backend} | VAD: {vad_status}")

    # Сначала гарантируем наличие скачанной модели с наглядным прогресс-баром
    ensure_model_downloaded(model_size)

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


def select_and_transcribe(cli_files: list[str] | None = None):
    valid_cli = [os.path.abspath(p) for p in (cli_files or []) if os.path.isfile(p)]
    if valid_cli:
        video_paths = valid_cli
    else:
        root = tk.Tk()
        root.withdraw()
        root.attributes("-topmost", True)

        print("[*] Выберите ОДНО или НЕСКОЛЬКО видео в появившемся окне (через Ctrl или Shift)...")
        selected = filedialog.askopenfilenames(
            title="Выберите видеофайлы для расшифровки и объединения",
            filetypes=[
                ("Видео и Аудио", "*.mp4 *.mkv *.avi *.mov *.mp3 *.wav *.m4a *.webm *.flac *.ogg"),
                ("Все файлы", "*.*"),
            ],
        )
        try:
            root.destroy()
        except Exception:
            pass

        if not selected:
            print("[!] Файлы не выбраны. Завершение работы.")
            return

        video_paths = sorted(list(selected))

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
    select_and_transcribe(sys.argv[1:])
