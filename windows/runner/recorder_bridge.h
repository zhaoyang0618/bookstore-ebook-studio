#ifndef RUNNER_RECORDER_BRIDGE_H_
#define RUNNER_RECORDER_BRIDGE_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <atomic>
#include <memory>
#include <string>
#include <thread>

#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>

// 裁剪区域（窗口客户区物理像素；w/h<=0 表示整窗）。
struct CaptureRegion {
  int x = 0;
  int y = 0;
  int w = 0;
  int h = 0;
};

// 录课桥接（设计文档 3.5：Windows 桌面端）。
//
// 用 PrintWindow(PW_RENDERFULLCONTENT) 逐帧抓取**本应用窗口**的内容
// （Flutter 是 ANGLE/D3D 渲染，必须带 PW_RENDERFULLCONTENT 才能抓到），
// 交给 Media Foundation SinkWriter 编码 H.264 输出 MP4。
// 不引 C++/WinRT，只用 Win32 + COM。
//
// 注意：v1 只录视频轨，不含音频（WASAPI 麦克风采集待后续版本）。
// Dart 侧见 lib/features/recorder/record_page.dart（channel: ebook_studio/recorder）。
class RecorderBridge {
 public:
  RecorderBridge(HWND window, flutter::BinaryMessenger* messenger);
  ~RecorderBridge();

  RecorderBridge(const RecorderBridge&) = delete;
  RecorderBridge& operator=(const RecorderBridge&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // 成功返回空串，失败返回原因（直接透给 Dart）。
  std::string StartRecording(int fps, const CaptureRegion& crop, int out_w, int out_h);
  std::string StopRecording(int64_t* seconds_out);

  // 采集线程主体：定时 PrintWindow → 写帧。
  void CaptureLoop(LONGLONG frame_interval_100ns);

  bool WriteFrame(LONGLONG pts_100ns);

  HWND window_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;

  std::atomic<bool> recording_{false};
  std::atomic<bool> writer_failed_{false};
  std::thread capture_thread_;
  std::string output_path_;   // UTF-8，回传 Dart 用
  std::wstring output_path_w_;  // 宽字符，文件系统用（中文用户名不乱码）
  int fps_ = 30;
  CaptureRegion crop_;        // 内容区裁剪（客户区物理像素，每帧钳制到窗口内）
  LONGLONG start_tick_ = 0;   // QPC 计数
  LONGLONG tick_freq_ = 1;    // QPC 频率

  // 以下成员只在采集线程存活期间被采集线程访问（stop 先 join 再动）。
  IMFSinkWriter* sink_writer_ = nullptr;
  HDC target_dc_ = nullptr;     // 承载固定尺寸 DIB 的内存 DC
  HBITMAP target_dib_ = nullptr;
  BYTE* target_bits_ = nullptr; // DIB 内存（bottom-up，与 MF RGB32 语义一致）
  int target_stride_ = 0;
  int capture_w_ = 0;
  int capture_h_ = 0;

  HDC scratch_dc_ = nullptr;    // 承载「当前窗口实际尺寸」的 DIB，可随窗口缩放
  HBITMAP scratch_dib_ = nullptr;
  int scratch_w_ = 0;
  int scratch_h_ = 0;
};

#endif  // RUNNER_RECORDER_BRIDGE_H_
