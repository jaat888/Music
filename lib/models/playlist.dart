// lib/models/playlist.dart
// Playlist data model — user ke banaye playlists ke liye.
//
// BATCH 14B: description aur isPrivate fields add kiye (pehle ye sirf
// UI me the, DB tak save nahi hote the — ab poora round-trip karte hain).

class Playlist {
  final String id;
  final String name;
  final String? description; // optional playlist description
  final String coverEmoji; // playlist cover ke liye emoji (e.g. "🎵")
  final String coverGradient; // gradient ka naam/key (theme me define hoga)
  final List<String> songIds; // songs ki id list, order maintain karti hai
  final DateTime createdAt;
  final bool isCollaborative;
  final bool isPrivate; // sirf owner ko dikhegi
  final String? folderId; // agar kisi folder ke andar hai to

  const Playlist({
    required this.id,
    required this.name,
    this.description,
    required this.coverEmoji,
    required this.coverGradient,
    required this.songIds,
    required this.createdAt,
    this.isCollaborative = false,
    this.isPrivate = false,
    this.folderId,
  });

  // ---------------- Map (SQLite DB ke liye) ----------------
  // songIds yahan store nahi hoti — wo alag playlist_songs table me
  // handled hoti hai (PlaylistDB dekho). Isliye toMap/fromMap me
  // songIds default empty rakhi hai; caller ko alag se load karna hoga.

  factory Playlist.fromMap(Map<String, dynamic> map, {List<String>? songIds}) {
    return Playlist(
      id: map['id'] as String,
      name: map['name'] as String? ?? 'Untitled',
      description: map['description'] as String?,
      coverEmoji: map['cover_emoji'] as String? ?? '🎵',
      coverGradient: map['cover_gradient'] as String? ?? 'default',
      songIds: songIds ?? const [],
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (map['created_at'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
      ),
      isCollaborative: (map['is_collaborative'] as int? ?? 0) == 1,
      isPrivate: (map['is_private'] as int? ?? 0) == 1,
      folderId: map['folder_id'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'cover_emoji': coverEmoji,
      'cover_gradient': coverGradient,
      'created_at': createdAt.millisecondsSinceEpoch,
      'is_collaborative': isCollaborative ? 1 : 0,
      'is_private': isPrivate ? 1 : 0,
      'folder_id': folderId,
    };
  }

  // ---------------- copyWith ----------------

  Playlist copyWith({
    String? id,
    String? name,
    String? description,
    String? coverEmoji,
    String? coverGradient,
    List<String>? songIds,
    DateTime? createdAt,
    bool? isCollaborative,
    bool? isPrivate,
    String? folderId,
  }) {
    return Playlist(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      coverEmoji: coverEmoji ?? this.coverEmoji,
      coverGradient: coverGradient ?? this.coverGradient,
      songIds: songIds ?? this.songIds,
      createdAt: createdAt ?? this.createdAt,
      isCollaborative: isCollaborative ?? this.isCollaborative,
      isPrivate: isPrivate ?? this.isPrivate,
      folderId: folderId ?? this.folderId,
    );
  }

  @override
  bool operator ==(Object other) => other is Playlist && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Playlist($id, $name, songs: ${songIds.length})';
}
