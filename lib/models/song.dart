// lib/models/song.dart
// Song data model — har jagah (DB, UI, player) yahi class use hoti hai.

class Song {
  final String id; // YouTube video id ya unique id
  final String title;
  final String artist;
  final String thumb; // thumbnail URL
  final int duration; // seconds me
  final String? filePath; // agar downloaded/cached hai to local path

  const Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.thumb,
    required this.duration,
    this.filePath,
  });

  // ---------------- JSON (API / network ke liye) ----------------

  factory Song.fromJson(Map<String, dynamic> json) {
    return Song(
      id: json['id'] as String,
      title: json['title'] as String? ?? 'Unknown',
      artist: json['artist'] as String? ?? 'Unknown Artist',
      thumb: json['thumb'] as String? ?? '',
      duration: (json['duration'] as num?)?.toInt() ?? 0,
      filePath: json['filePath'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'artist': artist,
      'thumb': thumb,
      'duration': duration,
      'filePath': filePath,
    };
  }

  // ---------------- Map (SQLite DB ke liye) ----------------
  // Note: DB column names snake_case me hain, isliye toMap/fromMap
  // json wale se alag rakhe hain taaki dono jagah flexibility rahe.

  factory Song.fromMap(Map<String, dynamic> map) {
    return Song(
      id: map['id'] as String,
      title: map['title'] as String? ?? 'Unknown',
      artist: map['artist'] as String? ?? 'Unknown Artist',
      thumb: map['thumb'] as String? ?? '',
      duration: (map['duration'] as num?)?.toInt() ?? 0,
      filePath: map['file_path'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'artist': artist,
      'thumb': thumb,
      'duration': duration,
      'file_path': filePath,
    };
  }

  // ---------------- copyWith ----------------

  Song copyWith({
    String? id,
    String? title,
    String? artist,
    String? thumb,
    int? duration,
    String? filePath,
  }) {
    return Song(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      thumb: thumb ?? this.thumb,
      duration: duration ?? this.duration,
      filePath: filePath ?? this.filePath,
    );
  }

  @override
  bool operator ==(Object other) => other is Song && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Song($id, $title - $artist)';
}
