import 'package:serverpod/serverpod.dart';

/// Database and serialized model tracking TUS upload session state.
class TusUploadSession implements SerializableModel {
  final int? id;
  final String fileId;
  final int uploadLength;
  final int uploadOffset;
  final String? metadata;
  final bool isComplete;
  final DateTime expiresAt;

  TusUploadSession({
    this.id,
    required this.fileId,
    required this.uploadLength,
    required this.uploadOffset,
    this.metadata,
    required this.isComplete,
    required this.expiresAt,
  });

  TusUploadSession copyWith({
    int? id,
    String? fileId,
    int? uploadLength,
    int? uploadOffset,
    String? metadata,
    bool? isComplete,
    DateTime? expiresAt,
  }) {
    return TusUploadSession(
      id: id ?? this.id,
      fileId: fileId ?? this.fileId,
      uploadLength: uploadLength ?? this.uploadLength,
      uploadOffset: uploadOffset ?? this.uploadOffset,
      metadata: metadata ?? this.metadata,
      isComplete: isComplete ?? this.isComplete,
      expiresAt: expiresAt ?? this.expiresAt,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      if (id != null) 'id': id,
      'fileId': fileId,
      'uploadLength': uploadLength,
      'uploadOffset': uploadOffset,
      'metadata': metadata,
      'isComplete': isComplete,
      'expiresAt': expiresAt.toIso8601String(),
    };
  }

  factory TusUploadSession.fromJson(Map<String, dynamic> jsonSerialization) {
    return TusUploadSession(
      id: jsonSerialization['id'] as int?,
      fileId: jsonSerialization['fileId'] as String,
      uploadLength: jsonSerialization['uploadLength'] as int,
      uploadOffset: jsonSerialization['uploadOffset'] as int,
      metadata: jsonSerialization['metadata'] as String?,
      isComplete: jsonSerialization['isComplete'] as bool,
      expiresAt: DateTime.parse(jsonSerialization['expiresAt'] as String),
    );
  }
}
