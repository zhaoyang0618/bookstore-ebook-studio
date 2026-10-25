#include "recorder_bridge.h"

#include <chrono>
#include <cstring>
#include <string>

#include <flutter/standard_method_codec.h>
#include <wrl/client.h>

namespace {

using Microsoft::WRL::ComPtr;

constexpr wchar_t kChannelName[] = L"ebook_studio/recorder";

#ifndef PW_RENDERFULLCONTENT
// Win8.1+ 才有定义：抓取 DirectComposition / D3D 内容（Flutter 是 ANGLE 渲染，必需）
#define PW_RENDERFULLCONTENT 0x00000002
#endif

void SafeRelease(IUnknown* object) {
  if (object != nullptr) {
    object->Release();
  }
}

std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) {
    return "";
  }
  const int size = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(),
                                       static_cast<int>(wide.size()), nullptr, 0, nullptr, nullptr);
  std::string utf8(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()), utf8.data(), size,
                      nullptr, nullptr);
  return utf8;
}

// 生成 DIB（bottom-up，GDI 默认）供 PrintWindow / StretchBlt 绘制。
// bits 可为 nullptr（只画不读）。
bool CreateDib(HDC* out_dc, HBITMAP* out_bitmap, BYTE** out_bits, int width, int height) {
  HDC screen_dc = GetDC(nullptr);
  if (screen_dc == nullptr) {
    return false;
  }
  *out_dc = CreateCompatibleDC(screen_dc);
  ReleaseDC(nullptr, screen_dc);
  if (*out_dc == nullptr) {
    return false;
  }

  BITMAPINFO info = {};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width;
  info.bmiHeader.biHeight = height;  // 正数 = bottom-up
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;

  void* bits = nullptr;
  *out_bitmap = CreateDIBSection(*out_dc, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (*out_bitmap == nullptr || bits == nullptr) {
    DeleteDC(*out_dc);
    *out_dc = nullptr;
    return false;
  }
  if (out_bits != nullptr) {
    *out_bits = static_cast<BYTE*>(bits);
  }
  SelectObject(*out_dc, *out_bitmap);
  return true;
}

void DestroyDib(HDC* dc, HBITMAP* bitmap) {
  if (*bitmap != nullptr) {
    DeleteObject(*bitmap);
    *bitmap = nullptr;
  }
  if (*dc != nullptr) {
    DeleteDC(*dc);
    *dc = nullptr;
  }
}

// 毫秒时间戳文件名：yyyy-MM-dd-HHmmss.mp4
std::wstring TimestampFileName() {
  SYSTEMTIME st;
  GetLocalTime(&st);
  wchar_t buffer[64];
  swprintf(buffer, 64, L"%04u-%02u-%02u-%02u%02u%02u.mp4", st.wYear, st.wMonth, st.wDay, st.wHour,
           st.wMinute, st.wSecond);
  return buffer;
}

// %LOCALAPPDATA%\ebook_studio\recordings\{ts}.mp4
// （Dart 停止后把文件挪到最终位置；用宽字符，中文用户名不乱码）
std::wstring BuildOutputPath() {
  wchar_t appdata[MAX_PATH] = {0};
  GetEnvironmentVariableW(L"LOCALAPPDATA", appdata, MAX_PATH);
  std::wstring dir = std::wstring(appdata) + L"\\ebook_studio";
  CreateDirectoryW(dir.c_str(), nullptr);
  dir += L"\\recordings";
  CreateDirectoryW(dir.c_str(), nullptr);
  return dir + L"\\" + TimestampFileName();
}

}  // namespace

RecorderBridge::RecorderBridge(HWND window, flutter::BinaryMessenger* messenger)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) { HandleMethodCall(call, std::move(result)); });
}

RecorderBridge::~RecorderBridge() {
  if (channel_ != nullptr) {
    channel_->SetMethodCallHandler(nullptr);
  }
  if (recording_.load()) {
    recording_.store(false);
    if (capture_thread_.joinable()) {
      capture_thread_.join();
    }
  }
}

void RecorderBridge::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name().compare("startRecording") == 0) {
    int fps = 30;
    if (const auto* args = std::get_if<flutter::EncodableMap>(call.arguments())) {
      const auto fps_it = args->find(flutter::EncodableValue("fps"));
      if (fps_it != args->end()) {
        if (const auto* fps_value = std::get_if<int32_t>(&fps_it->second)) {
          fps = *fps_value;
        }
      }
    }
    const std::string error = StartRecording(fps);
    if (error.empty()) {
      result->Success(nullptr);
    } else {
      result->Error("START_FAILED", error, nullptr);
    }
  } else if (call.method_name().compare("stopRecording") == 0) {
    int64_t seconds = 0;
    const std::string error = StopRecording(&seconds);
    if (error.empty()) {
      flutter::EncodableMap response;
      response[flutter::EncodableValue("path")] = flutter::EncodableValue(output_path_);
      response[flutter::EncodableValue("duration_seconds")] =
          flutter::EncodableValue(static_cast<int32_t>(seconds));
      flutter::EncodableValue value(std::move(response));
      result->Success(&value);
    } else {
      result->Error("STOP_FAILED", error, nullptr);
    }
  } else {
    result->NotImplemented();
  }
}

std::string RecorderBridge::StartRecording(int fps) {
  if (recording_.load()) {
    return "已经在录制中";
  }
  if (window_ == nullptr || !IsWindow(window_)) {
    return "窗口不可用";
  }
  if (IsIconic(window_)) {
    return "窗口处于最小化，无法录制";
  }

  RECT client;
  GetClientRect(window_, &client);
  // 编码器要求偶数尺寸
  const int width = (client.right - client.left) & ~1;
  const int height = (client.bottom - client.top) & ~1;
  if (width < 16 || height < 16) {
    return "窗口尺寸过小，无法录制";
  }
  if (fps < 1 || fps > 60) {
    fps = 30;
  }
  fps_ = fps;
  output_path_w_ = BuildOutputPath();
  output_path_ = WideToUtf8(output_path_w_);

  // MF 生命周期：每次录制一对 Startup / Shutdown
  HRESULT hr = MFStartup(MF_VERSION, MFSTARTUP_LITE);
  if (FAILED(hr)) {
    return "Media Foundation 初始化失败";
  }

  ComPtr<IMFMediaType> out_type;
  ComPtr<IMFMediaType> in_type;
  std::string error;

  do {
    hr = MFCreateSinkWriterFromURL(output_path_w_.c_str(), nullptr, nullptr, &sink_writer_);
    if (FAILED(hr)) {
      error = "无法创建视频文件";
      break;
    }

    // 输出：H.264
    hr = MFCreateMediaType(&out_type);
    if (SUCCEEDED(hr)) {
      hr = out_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    }
    if (SUCCEEDED(hr)) {
      hr = out_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
    }
    if (SUCCEEDED(hr)) {
      hr = MFSetAttributeSize(out_type.Get(), MF_MT_FRAME_SIZE, width, height);
    }
    if (SUCCEEDED(hr)) {
      hr = MFSetAttributeRatio(out_type.Get(), MF_MT_FRAME_RATE, fps, 1);
    }
    if (SUCCEEDED(hr)) {
      hr = MFSetAttributeRatio(out_type.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    }
    if (SUCCEEDED(hr)) {
      hr = out_type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    }
    if (SUCCEEDED(hr)) {
      hr = out_type->SetUINT32(MF_MT_AVG_BITRATE, 8000000);
    }
    if (FAILED(hr)) {
      error = "配置视频输出参数失败";
      break;
    }

    DWORD stream_index = 0;
    hr = sink_writer_->AddStream(out_type.Get(), &stream_index);
    if (FAILED(hr)) {
      error = "无法添加视频流";
      break;
    }

    // 输入：RGB32（GDI DIB 的原生格式），由 SinkWriter 自动插入转换器转 NV12
    hr = MFCreateMediaType(&in_type);
    if (SUCCEEDED(hr)) {
      hr = in_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    }
    if (SUCCEEDED(hr)) {
      hr = in_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
    }
    if (SUCCEEDED(hr)) {
      hr = MFSetAttributeSize(in_type.Get(), MF_MT_FRAME_SIZE, width, height);
    }
    if (SUCCEEDED(hr)) {
      hr = MFSetAttributeRatio(in_type.Get(), MF_MT_FRAME_RATE, fps, 1);
    }
    if (FAILED(hr)) {
      error = "配置视频输入参数失败";
      break;
    }

    hr = sink_writer_->SetInputMediaType(0, in_type.Get(), nullptr);
    if (FAILED(hr)) {
      error = "RGB32 → H.264 转换器初始化失败";
      break;
    }

    hr = sink_writer_->BeginWriting();
    if (FAILED(hr)) {
      error = "编码器启动失败";
      break;
    }
  } while (false);

  if (!error.empty()) {
    SafeRelease(sink_writer_);
    sink_writer_ = nullptr;
    MFShutdown();
    DeleteFileW(output_path_w_.c_str());
    return error;
  }

  // 固定尺寸的目标 DIB（SinkWriter 的尺寸不能中途改；窗口缩放时靠 StretchBlt 缩放）
  if (!CreateDib(&target_dc_, &target_dib_, &target_bits_, width, height)) {
    SafeRelease(sink_writer_);
    sink_writer_ = nullptr;
    MFShutdown();
    DeleteFileW(output_path_w_.c_str());
    return "无法创建采集缓冲";
  }
  target_stride_ = width * 4;
  capture_w_ = width;
  capture_h_ = height;

  LARGE_INTEGER freq;
  QueryPerformanceFrequency(&freq);
  tick_freq_ = freq.QuadPart;
  LARGE_INTEGER counter;
  QueryPerformanceCounter(&counter);
  start_tick_ = counter.QuadPart;

  writer_failed_.store(false);
  recording_.store(true);
  capture_thread_ = std::thread([this, frame_interval = static_cast<LONGLONG>(10000000 / fps)]() {
    CaptureLoop(frame_interval);
  });
  return "";
}

void RecorderBridge::CaptureLoop(LONGLONG frame_interval_100ns) {
  LONGLONG next_100ns = 0;
  while (recording_.load()) {
    if (IsWindow(window_) && !IsIconic(window_)) {
      RECT client;
      GetClientRect(window_, &client);
      const int w = client.right - client.left;
      const int h = client.bottom - client.top;

      if (w >= 2 && h >= 2) {
        // 窗口尺寸与上次不同（缩放 / DPI 变化）→ 重建 scratch DIB
        if (w != scratch_w_ || h != scratch_h_) {
          DestroyDib(&scratch_dc_, &scratch_dib_);
          CreateDib(&scratch_dc_, &scratch_dib_, nullptr, w, h);
          scratch_w_ = w;
          scratch_h_ = h;
        }
        if (scratch_dc_ != nullptr &&
            PrintWindow(window_, scratch_dc_, PW_RENDERFULLCONTENT)) {
          // 统一缩放到固定目标尺寸（尺寸相同时等于直接拷贝）
          SetStretchBltMode(target_dc_, HALFTONE);
          StretchBlt(target_dc_, 0, 0, capture_w_, capture_h_, scratch_dc_, 0, 0, w, h, SRCCOPY);

          LARGE_INTEGER counter;
          QueryPerformanceCounter(&counter);
          const LONGLONG pts = (counter.QuadPart - start_tick_) * 10000000 / tick_freq_;
          if (!WriteFrame(pts)) {
            writer_failed_.store(true);
            break;
          }
        }
      }
    }
    // 最小化 / 窗口失效：跳帧，时间轴继续（输出为定格画面）

    if (next_100ns == 0) {
      LARGE_INTEGER counter;
      QueryPerformanceCounter(&counter);
      next_100ns = (counter.QuadPart - start_tick_) * 10000000 / tick_freq_;
    }
    next_100ns += frame_interval_100ns;

    LARGE_INTEGER counter;
    QueryPerformanceCounter(&counter);
    const LONGLONG now_100ns = (counter.QuadPart - start_tick_) * 10000000 / tick_freq_;
    if (next_100ns < now_100ns) {
      next_100ns = now_100ns;  // 落后了就对齐当前时刻，不追赶补帧
      continue;
    }
    std::this_thread::sleep_for(std::chrono::microseconds((next_100ns - now_100ns) / 10));
  }
}

bool RecorderBridge::WriteFrame(LONGLONG pts_100ns) {
  ComPtr<IMFSample> sample;
  ComPtr<IMFMediaBuffer> buffer;
  const int buffer_size = target_stride_ * capture_h_;

  HRESULT hr = MFCreateSample(&sample);
  if (SUCCEEDED(hr)) {
    hr = MFCreateMemoryBuffer(buffer_size, &buffer);
  }
  if (SUCCEEDED(hr)) {
    BYTE* dst = nullptr;
    hr = buffer->Lock(&dst, nullptr, nullptr);
    if (SUCCEEDED(hr)) {
      memcpy(dst, target_bits_, static_cast<size_t>(buffer_size));
      buffer->Unlock();
      buffer->SetCurrentLength(static_cast<DWORD>(buffer_size));
    }
  }
  if (SUCCEEDED(hr)) {
    hr = sample->AddBuffer(buffer.Get());
  }
  if (SUCCEEDED(hr)) {
    hr = sample->SetSampleTime(pts_100ns);
  }
  if (SUCCEEDED(hr)) {
    hr = sample->SetSampleDuration(10000000 / fps_);
  }
  if (SUCCEEDED(hr)) {
    hr = sink_writer_->WriteSample(0, sample.Get());
  }
  return SUCCEEDED(hr);
}

std::string RecorderBridge::StopRecording(int64_t* seconds_out) {
  if (!recording_.load()) {
    return "当前没有正在进行的录制";
  }
  recording_.store(false);
  if (capture_thread_.joinable()) {
    capture_thread_.join();
  }

  std::string error;
  if (writer_failed_.load()) {
    error = "视频写入失败（磁盘空间或编码器异常）";
  } else {
    const HRESULT hr = sink_writer_->Finalize();
    if (FAILED(hr)) {
      error = "视频封装失败（可能录制时间过短）";
    }
  }

  LARGE_INTEGER counter;
  QueryPerformanceCounter(&counter);
  *seconds_out = static_cast<int64_t>((counter.QuadPart - start_tick_) * tick_freq_ / 10000000);

  SafeRelease(sink_writer_);
  sink_writer_ = nullptr;
  DestroyDib(&target_dc_, &target_dib_);
  DestroyDib(&scratch_dc_, &scratch_dib_);
  scratch_w_ = 0;
  scratch_h_ = 0;
  MFShutdown();

  if (!error.empty()) {
    DeleteFileW(output_path_w_.c_str());
  }
  return error;
}
