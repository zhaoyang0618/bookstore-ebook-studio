/// 网盘抽象层（设计文档 2.5 / 3.4 / 4.3）。
///
/// `RemoteProvider` 抽象类与 dsh 版（TypeScript interface）是**同一份契约**，
/// 只是语言不同（设计文档 4.3「接口是契约，实现是自由的」）。
library;

import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

/// 网盘上的一个文件 / 目录条目。
class RemoteFile {
  const RemoteFile({
    required this.path,
    required this.isDirectory,
    required this.sizeBytes,
    required this.modifiedAt,
    this.etag,
  });

  final String path;
  final bool isDirectory;
  final int sizeBytes;
  final String modifiedAt;
  final String? etag;

  factory RemoteFile.fromJson(Map<String, dynamic> json) => RemoteFile(
        path: json['path'] as String,
        isDirectory: json['isDirectory'] as bool? ?? false,
        sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
        modifiedAt: json['modifiedAt'] as String? ?? '',
        etag: json['etag'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'path': path,
        'isDirectory': isDirectory,
        'sizeBytes': sizeBytes,
        'modifiedAt': modifiedAt,
        if (etag != null) 'etag': etag,
      };
}

/// 拉取路径（设计文档 2.5）。
enum PullStrategy { downloadThenUpload, remoteCopy }

/// 网盘抽象接口（设计文档 2.5）。
///
/// 所有网盘 API 变更都隔离在各自的适配器里（设计文档第七部分风险应对）。
abstract class RemoteProvider {
  /// `webdav` 或 `baidu`。
  String get id;

  Future<void> authenticate();

  Future<List<RemoteFile>> listFiles(String path);

  Future<void> downloadFile(String remotePath, String localPath);

  Future<void> uploadFile(String localPath, String remotePath);

  Future<void> copyFile(String src, String dst);

  Future<void> moveFile(String src, String dst);

  bool isConnected();
}

/// WebDAV 配置。
class WebDavConfig {
  const WebDavConfig({
    required this.baseUrl,
    required this.username,
    required this.password,
    required this.rootPath,
  });

  /// 例如 `https://dav.jianguoyun.com/dav/`
  final String baseUrl;

  /// 用户名。
  final String username;

  /// 应用密码（非登录密码）。
  final String password;

  /// MyLibrary 在网盘上的根路径。
  final String rootPath;

  Map<String, dynamic> toJson() => {
        'baseUrl': baseUrl,
        'username': username,
        'rootPath': rootPath,
        // password 只在内存中使用，不序列化
      };
}

/// WebDAV 适配器（设计文档 2.5：坚果云 / Nextcloud / 群晖 NAS）。
class WebDavProvider implements RemoteProvider {
  WebDavProvider(this.config, {http.Client? client}) : _client = client ?? http.Client();

  final WebDavConfig config;
  final http.Client _client;
  bool _connected = false;

  @override
  String get id => 'webdav';

  @override
  bool isConnected() => _connected;

  String _urlFor(String path) => '${config.baseUrl.replaceAll(RegExp(r'/+$'), '')}${path.startsWith('/') ? path : '/$path'}';

  Map<String, String> _headers([Map<String, String>? extra]) {
    final credentials = base64Encode(utf8.encode('${config.username}:${config.password}'));
    return {
      'Authorization': 'Basic $credentials',
      ...?extra,
    };
  }

  @override
  Future<void> authenticate() async {
    final response = await _client.send(
      http.Request('PROPFIND', Uri.parse(_urlFor(config.rootPath)))
        ..headers.addAll(_headers({'Depth': '0'})),
    );
    // 207 Multi-Status 表示成功；部分服务器返回 200
    if (response.statusCode != 207 && response.statusCode != 200) {
      throw HttpException('WebDAV 认证失败：HTTP ${response.statusCode}');
    }
    _connected = true;
  }

  @override
  Future<List<RemoteFile>> listFiles(String path) async {
    final response = await _client.send(
      http.Request('PROPFIND', Uri.parse(_urlFor(path)))
        ..headers.addAll(_headers({'Depth': '1', 'Content-Type': 'application/xml'})),
    );
    if (response.statusCode != 207) {
      throw HttpException('WebDAV 列表失败：HTTP ${response.statusCode}');
    }
    final body = await response.stream.bytesToString();
    return parseWebDavMultistatus(body, path);
  }

  @override
  Future<void> downloadFile(String remotePath, String localPath) async {
    final response = await _client.send(http.Request('GET', Uri.parse(_urlFor(remotePath)))..headers.addAll(_headers()));
    if (response.statusCode != 200) {
      throw HttpException('WebDAV 下载失败：HTTP ${response.statusCode}');
    }
    final file = File(localPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(await response.stream.toBytes());
  }

  @override
  Future<void> uploadFile(String localPath, String remotePath) async {
    final bytes = await File(localPath).readAsBytes();
    final response = await _client.send(
      http.Request('PUT', Uri.parse(_urlFor(remotePath)))
        ..headers.addAll(_headers())
        ..bodyBytes = bytes,
    );
    if (response.statusCode != 200 && response.statusCode != 201 && response.statusCode != 204) {
      throw HttpException('WebDAV 上传失败：HTTP ${response.statusCode}');
    }
  }

  @override
  Future<void> copyFile(String src, String dst) async {
    final response = await _client.send(
      http.Request('COPY', Uri.parse(_urlFor(src)))
        ..headers.addAll(_headers({'Destination': _urlFor(dst), 'Overwrite': 'T'})),
    );
    if (response.statusCode != 200 && response.statusCode != 201 && response.statusCode != 204) {
      throw HttpException('WebDAV 复制失败：HTTP ${response.statusCode}');
    }
  }

  @override
  Future<void> moveFile(String src, String dst) async {
    final response = await _client.send(
      http.Request('MOVE', Uri.parse(_urlFor(src)))
        ..headers.addAll(_headers({'Destination': _urlFor(dst), 'Overwrite': 'T'})),
    );
    if (response.statusCode != 200 && response.statusCode != 201 && response.statusCode != 204) {
      throw HttpException('WebDAV 移动失败：HTTP ${response.statusCode}');
    }
  }
}

/// 解析 WebDAV `207 Multi-Status` 响应体中的条目（与 TS 版一致）。
List<RemoteFile> parseWebDavMultistatus(String xml, String basePath) {
  final document = XmlDocument.parse(xml);
  final files = <RemoteFile>[];
  for (final response in document.findAllElements('response')) {
    final href = response.getElement('href')?.innerText;
    if (href == null) continue;
    final path = Uri.decodeFull(href);
    if (path == basePath || '$path/' == basePath) continue;
    final isCollection = response.findAllElements('collection').isNotEmpty;
    final sizeText = response.getElement('getcontentlength')?.innerText;
    final modified = response.getElement('getlastmodified')?.innerText;
    files.add(RemoteFile(
      path: path,
      isDirectory: isCollection,
      sizeBytes: sizeText != null ? int.tryParse(sizeText) ?? 0 : 0,
      modifiedAt: modified != null ? (HttpDate.parse(modified).toUtc().toIso8601String()) : DateTime.fromMillisecondsSinceEpoch(0, isUtc: true).toIso8601String(),
    ));
  }
  return files;
}

/// 百度网盘配置。
class BaiduConfig {
  const BaiduConfig({required this.accessToken, required this.appName});

  final String accessToken;

  /// 百度网盘限制应用只能访问 `/apps/{产品名}/` 目录。
  final String appName;
}

/// 百度网盘适配器（设计文档 2.5）。
///
/// 注意事项：
/// - `/apps/{产品名}/` 目录限制
/// - OAuth `refresh_token` **只能使用一次**，刷新后旧 token 立即失效
/// - 推荐先用 **alist** 把百度网盘挂载为 WebDAV，复用 WebDAV 适配器
class BaiduProvider implements RemoteProvider {
  BaiduProvider(this.config, {http.Client? client}) : _client = client ?? http.Client();

  final BaiduConfig config;
  final http.Client _client;
  bool _connected = false;

  @override
  String get id => 'baidu';

  @override
  bool isConnected() => _connected;

  String get _appRoot => '/apps/${config.appName}';

  Uri _uri(String path, [Map<String, String> query = const {}]) => Uri.https('pan.baidu.com', path, {
        'access_token': config.accessToken,
        ...query,
      });

  @override
  Future<void> authenticate() async {
    final response = await _client.get(_uri('/rest/2.0/xpan/file', {'method': 'list', 'dir': _appRoot, 'limit': '1'}));
    if (response.statusCode != 200) {
      throw HttpException('百度网盘认证失败：HTTP ${response.statusCode}');
    }
    _connected = true;
  }

  @override
  Future<List<RemoteFile>> listFiles(String path) async {
    final response = await _client.get(_uri('/rest/2.0/xpan/file', {'method': 'list', 'dir': path, 'limit': '1000'}));
    if (response.statusCode != 200) {
      throw HttpException('百度网盘列表失败：HTTP ${response.statusCode}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final list = (body['list'] as List?)?.whereType<Map<String, dynamic>>() ?? const [];
    return list.map((entry) {
      return RemoteFile(
        path: entry['path'] as String? ?? '',
        isDirectory: (entry['isdir'] as num?)?.toInt() == 1,
        sizeBytes: (entry['size'] as num?)?.toInt() ?? 0,
        modifiedAt: DateTime.fromMillisecondsSinceEpoch(((entry['server_mtime'] as num?)?.toInt() ?? 0) * 1000, isUtc: true).toIso8601String(),
      );
    }).toList();
  }

  @override
  Future<void> downloadFile(String remotePath, String localPath) async {
    // 百度网盘需要先获取 dlink 再下载
    final meta = await _client.get(_uri('/rest/2.0/xpan/multimedia', {'method': 'filemetas', 'fsids': '', 'dlink': '1', 'path': remotePath}));
    if (meta.statusCode != 200) {
      throw HttpException('百度网盘获取下载链接失败：HTTP ${meta.statusCode}');
    }
    final body = jsonDecode(meta.body) as Map<String, dynamic>;
    final list = (body['list'] as List?)?.whereType<Map<String, dynamic>>() ?? const [];
    final dlink = list.isNotEmpty ? list.first['dlink'] as String? : null;
    if (dlink == null) throw HttpException('百度网盘未返回下载链接：$remotePath');
    final file = await _client.get(Uri.parse('$dlink&access_token=${Uri.encodeQueryComponent(config.accessToken)}'));
    if (file.statusCode != 200) {
      throw HttpException('百度网盘下载失败：HTTP ${file.statusCode}');
    }
    final target = File(localPath);
    await target.parent.create(recursive: true);
    await target.writeAsBytes(file.bodyBytes);
  }

  @override
  Future<void> uploadFile(String localPath, String remotePath) {
    // 百度网盘分片上传（设计文档 1.8.6）：precreate + 分片 + create，
    // 建议改用 WebDAV 适配器或 alist 挂载
    throw UnsupportedError('百度网盘上传需要分片流程，请改用 WebDAV 适配器或 alist 挂载');
  }

  @override
  Future<void> copyFile(String src, String dst) async {
    final response = await _client.post(
      _uri('/rest/2.0/xpan/file', {'method': 'filemanager', 'opera': 'copy'}),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: 'async=1&filelist=${Uri.encodeQueryComponent(jsonEncode([
            {'path': src, 'dest': dst, 'newtype': 1}
          ]))}',
    );
    if (response.statusCode != 200) {
      throw HttpException('百度网盘复制失败：HTTP ${response.statusCode}');
    }
  }

  @override
  Future<void> moveFile(String src, String dst) async {
    final response = await _client.post(
      _uri('/rest/2.0/xpan/file', {'method': 'filemanager', 'opera': 'move'}),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: 'async=1&filelist=${Uri.encodeQueryComponent(jsonEncode([
            {'path': src, 'dest': dst}
          ]))}',
    );
    if (response.statusCode != 200) {
      throw HttpException('百度网盘移动失败：HTTP ${response.statusCode}');
    }
  }
}

/// 选择拉取路径（设计文档 2.5）。
///
/// - **路径 A（下载→上传）**：源和目标不在同一网盘账号，或百度网盘普通目录
/// - **路径 B（网盘内复制/移动）**：WebDAV，效率更高
PullStrategy choosePullStrategy({
  required bool sameProvider,
  required String providerId,
  required bool sameAccount,
}) {
  if (sameProvider && providerId == 'webdav' && sameAccount) return PullStrategy.remoteCopy;
  return PullStrategy.downloadThenUpload;
}
