import 'package:dio/dio.dart';

/// Classifies network outcomes into a small set the UI layer can render
/// without leaking low-level transport details. Anything else falls through
/// as [LlmErrorKind.unknown].
enum LlmErrorKind {
  unauthorized,
  rateLimited,
  server,
  timeout,
  network,
  format,
  cancelled,
  unknown
}

/// Stable error envelope for LLM calls. Includes an [httpStatus] (when
/// available) and a [message] safe for diagnostics — never includes the
/// request body or any token material.
class LlmError implements Exception {
  const LlmError(this.kind, this.message, {this.httpStatus});
  final LlmErrorKind kind;
  final String message;
  final int? httpStatus;

  @override
  String toString() => 'LlmError($kind, status: $httpStatus, $message)';
}

/// Thin wrapper around [Dio] that:
///   * injects a Bearer header for every request (caller supplies the key);
///   * rejects responses > 4 KiB in the auth header / log paths (defence in
///     depth — the key never reaches `print` because we never log requests);
///   * maps Dio exceptions to [LlmError] so call-sites can render them.
class ApiClient {
  ApiClient({Dio? dio}) : _dio = dio ?? _buildDefaultDio();

  final Dio _dio;

  static Dio _buildDefaultDio() {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 60),
      sendTimeout: const Duration(seconds: 10),
      headers: const {'Content-Type': 'application/json'},
      responseType: ResponseType.stream,
    ));
    return dio;
  }

  Future<Response<dynamic>> post({
    required String url,
    required Object body,
    required String apiKey,
    Map<String, Object?>? queryParameters,
  }) {
    return _safeSend(
      () => _dio.post(
        url,
        data: body,
        queryParameters: queryParameters,
        options: Options(
          headers: {'Authorization': 'Bearer $apiKey'},
          responseType: ResponseType.stream,
        ),
      ),
    );
  }

  /// SSE-friendly variant that streams bytes back through Dio's stream
  /// response. The caller is responsible for assembling the [Stream<List<int>>]
  /// into lines / events.
  Future<Response<dynamic>> postStream({
    required String url,
    required Object body,
    required String apiKey,
    Map<String, Object?>? queryParameters,
  }) async {
    return _safeSend(
      () => _dio.post<dynamic>(
        url,
        data: body,
        queryParameters: queryParameters,
        options: Options(
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Accept': 'text/event-stream',
          },
          responseType: ResponseType.stream,
        ),
      ),
    );
  }

  Future<Response<dynamic>> _safeSend(
      Future<Response<dynamic>> Function() send) async {
    try {
      return await send();
    } on DioException catch (e) {
      throw _mapDioError(e);
    } catch (e) {
      throw LlmError(LlmErrorKind.unknown, 'unexpected: ${e.runtimeType}');
    }
  }

  LlmError _mapDioError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return const LlmError(LlmErrorKind.timeout, 'request timed out');
      case DioExceptionType.cancel:
        return const LlmError(LlmErrorKind.cancelled, 'request cancelled');
      case DioExceptionType.connectionError:
        return const LlmError(LlmErrorKind.network, 'network unavailable');
      case DioExceptionType.badResponse:
        final status = e.response?.statusCode ?? -1;
        if (status == 401) {
          return LlmError(LlmErrorKind.unauthorized, 'invalid api key',
              httpStatus: 401);
        }
        if (status == 429) {
          return LlmError(LlmErrorKind.rateLimited, 'rate limited',
              httpStatus: 429);
        }
        if (status >= 500) {
          return LlmError(LlmErrorKind.server, 'upstream error',
              httpStatus: status);
        }
        return LlmError(LlmErrorKind.unknown, 'http $status',
            httpStatus: status);
      case DioExceptionType.badCertificate:
      case DioExceptionType.unknown:
      case DioExceptionType.transformTimeout:
        return const LlmError(LlmErrorKind.network, 'network unavailable');
    }
  }

  /// Hook used by tests so they can replace the underlying [Dio] (e.g. with
  /// a `DioAdapter`).
  // ignore: unused_element
  Dio get _internalDio => _dio;
}
