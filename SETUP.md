# SurSathi Setup Guide

## Kya hai ye

SurSathi ek Flutter-based music player app hai jo Hindi, Haryanvi aur
Punjabi gaane YouTube se search karke stream/download karta hai. Poora
app local-only hai — koi login, koi backend server, koi account system
nahi. Sab kuch (liked songs, playlists, downloads, cache, settings)
seedha device pe local store hota hai (SQLite + SharedPreferences).
App PC ke bina, seedha phone se GitHub Actions ke through build hoti hai.

## Requirements

- Flutter SDK `3.19.0` (GitHub Actions workflow isi version ko pin karega)
- Ek GitHub account (private repo: `github.com/jaat888/SurSathi`)
- Ek Android phone jispe APK install karna hai
- Internet connection (build ke waqt aur app use karte waqt dono)

## File Structure

```
sursathi/
├── android/
│   └── app/src/main/AndroidManifest.xml
├── lib/
│   ├── main.dart
│   ├── theme/
│   │   ├── colors.dart
│   │   ├── typography.dart
│   │   └── app_theme.dart
│   ├── models/
│   │   ├── song.dart
│   │   └── playlist.dart
│   ├── db/
│   │   ├── liked_db.dart
│   │   ├── cache_db.dart
│   │   ├── playlist_db.dart
│   │   └── download_db.dart
│   ├── services/
│   │   ├── cache_service.dart
│   │   ├── like_service.dart
│   │   ├── storage_service.dart
│   │   ├── theme_service.dart
│   │   ├── queue_service.dart
│   │   ├── search_history.dart
│   │   ├── youtube_service.dart
│   │   ├── audio_focus_service.dart
│   │   ├── notification_service.dart
│   │   └── background_service.dart
│   ├── widgets/
│   │   ├── song_card.dart
│   │   ├── category_card.dart
│   │   ├── section_header.dart
│   │   ├── equalizer_bars.dart
│   │   ├── shimmer_song_card.dart
│   │   ├── mini_player.dart
│   │   ├── rotating_vinyl.dart
│   │   ├── progress_slider.dart
│   │   ├── animated_play_button.dart
│   │   ├── heart_button.dart
│   │   └── cache_indicator.dart
│   └── screens/
│       ├── splash_screen.dart
│       ├── onboarding_screen.dart
│       ├── permission_screen.dart
│       ├── language_screen.dart
│       ├── taste_screen.dart
│       ├── home_screen.dart
│       ├── search_screen.dart
│       ├── library_screen.dart
│       ├── downloads_screen.dart
│       ├── full_player_screen.dart
│       ├── queue_screen.dart
│       ├── lyrics_screen.dart
│       ├── equalizer_screen.dart
│       ├── create_playlist_screen.dart
│       ├── playlist_detail_screen.dart
│       ├── add_to_playlist_sheet.dart
│       ├── liked_songs_screen.dart
│       ├── artist_screen.dart
│       ├── album_screen.dart
│       ├── cache_manager_screen.dart
│       ├── profile_screen.dart
│       ├── stats_screen.dart
│       ├── settings_screen.dart
│       ├── background_settings_screen.dart
│       ├── about_screen.dart
│       └── help_screen.dart
├── pubspec.yaml
├── analysis_options.yaml
├── README.md
├── NOTES.md
└── SETUP.md
```

## GitHub pe kaise upload kare (zip workflow)

Phone se seedha bade zip files GitHub web UI pe upload karna mushkil
hai, isliye ek `.github/workflows/extract.yml` workflow use hota hai
jo repo me daale gaye zip ko khud extract kar deta hai:

1. Batch ka zip (jaisa Claude deta hai) apne phone me download karo.
2. GitHub repo kholo → **Add file → Upload files**.
3. Zip file ko seedha upload kar do (kisi folder ke andar nahi, root
   me — jaise `batch13.zip`).
4. Commit karo (`Add batch 13`) — isse **Actions** tab me
   `extract.yml` workflow trigger ho jayega.
5. Workflow zip ke andar ki files ko `lib/`, `android/` etc. ke sahi
   path pe extract/copy kar deta hai aur ek naya commit push kar deta
   hai. Zip file khud repo se hata di jaati hai (cleanup step).
6. Actions tab me green tick aane tak wait karo — agar red cross aaye
   to logs kholke dekho kya error hai.

## APK Build (GitHub Actions)

1. Repo me `.github/workflows/build.yml` workflow hai jo Flutter setup
   karke `flutter build apk --release` chalata hai.
2. Ye workflow trigger hota hai jab bhi `lib/` ya `pubspec.yaml` me kuch
   push hota hai (ya manually **Actions → Build APK → Run workflow**
   se bhi chala sakte ho).
3. Build complete hone pe **Actions** tab → us run ko kholo → neeche
   **Artifacts** section me `sursathi-release-apk` milega — usko
   download karo (zip me APK hoga).
4. Phone pe zip ko extract karke `.apk` file kholo. "Unknown sources"
   se install allow karna padega (ek baar).
5. Install ho jaane pe app open karo.

## Troubleshooting

- **Build fail ho raha hai:** Locally ya Actions logs me
  `flutter clean` fir `flutter pub get` chalao, phir dobara build
  try karo. Zyada tar dependency version conflicts isse fix ho jaate
  hain.
- **App crash ho rahi hai start pe:** Storage aur notification
  permissions check karo (Settings → Apps → SurSathi → Permissions).
  Android 13+ pe pehli baar khulte hi permission dialog dikhna
  chahiye — agar deny kiya ho to manually ON karo.
- **Sound nahi aa raha:** Internet check karo. YouTube ne kabhi kabhi
  temporarily block kar diya hota hai — download karke offline try
  karo, ya thodi der baad dobara.
- **Background me nahi chal raha:** Settings → Background & Battery →
  "Continue in background" ON karo, aur battery optimization bhi off
  karo (phone-specific steps ke liye Settings screen ka info card
  dekho).
- **YouTube URL fail ho raha hai baar baar:** `youtube_explode_dart`
  package ko latest version pe update karo — YouTube apni internal
  API kabhi kabhi change kar deta hai jisse purana package version
  break ho jaata hai.

## Features (poora app scope)

- YouTube search + stream + download (Music/SurSathi/ folder)
- Home categories (Bollywood, Punjabi, Haryanvi, Lo-Fi, Party,
  Romantic, Workout, Old Hits, Arijit, Chill, Devotional, Hip-Hop)
- Live debounced search + recent searches
- Liked Songs (heart animation), Playlists (create/edit/reorder)
- Auto-cache (2GB default, LRU eviction, liked songs protected)
- Mini player + full player (rotating vinyl, equalizer bars, sleep
  timer, queue, lyrics)
- Background playback + notification + lock-screen controls
- Shuffle, repeat, crossfade, gapless (settings-level toggles)
- Equalizer (10-band + presets + bass boost + 3D surround + reverb)
- Cache Manager (storage ring chart, limit slider, protected songs)
- Profile + Stats (liked/playlists/downloads counts, listening stats)
- Full Settings screen (appearance, playback, downloads, cache,
  notifications, privacy, background, audio, advanced, about)
- Help & FAQ with search
- Heavy animations throughout (stagger, slide, fade, scale, shimmer)
- Onboarding (splash, language, permissions, taste picker)

## Credits

- Developer: Jaat888
- Built batch-by-batch with Claude (Anthropic)
- Music streamed via YouTube (`youtube_explode_dart`)
- Fonts: Sora + Inter (Google Fonts)

## License

Personal use only. Educational purpose. Ye app kisi bhi commercial
use ke liye nahi hai — sirf shauk aur seekhne ke liye banaya gaya hai.
YouTube content ke rights unke respective owners ke paas hain.
