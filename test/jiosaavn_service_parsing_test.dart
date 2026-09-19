import 'package:flutter_test/flutter_test.dart';
import 'package:sursathi/services/jiosaavn_service.dart';

void main() {
  final svc = JioSaavnService.instance;

  test('legacy shape: playlist name in `listname` is no longer skipped', () {
    final p = svc.debugPreviewFrom({
      'listid': '1234',
      'listname': 'Bollywood Hits &amp; Love',
      'image': 'https://c.saavncdn.com/x-150x150.jpg',
    });
    expect(p, isNotNull);
    expect(p!.id, '1234');
    expect(p.title, 'Bollywood Hits & Love');
    expect(p.thumb, contains('500x500'));
  });

  test('v4 shape: id/title/image string', () {
    final p = svc.debugPreviewFrom({
      'id': '999',
      'title': 'Punjabi Hits',
      'subtitle': '',
      'image': 'https://c.saavncdn.com/y-150x150.jpg',
    });
    expect(p!.title, 'Punjabi Hits');
    expect(p.subtitle, 'JioSaavn');
  });

  test('saavn.dev shape: name + image list gets sd: prefix', () {
    final p = svc.debugPreviewFrom({
      'id': '55',
      'name': 'Haryanvi Hits',
      'songCount': 30,
      'image': [
        {'quality': '50x50', 'url': 'https://a/50.jpg'},
        {'quality': '500x500', 'url': 'https://a/500.jpg'},
      ],
    }, idPrefix: 'sd:');
    expect(p!.id, 'sd:55');
    expect(p.title, 'Haryanvi Hits');
    expect(p.thumb, 'https://a/500.jpg');
    expect(p.subtitle, '30 songs');
  });

  test('item without id/title is skipped', () {
    expect(svc.debugPreviewFrom({'image': 'x'}), isNull);
  });

  test('tracks: legacy songs/singers', () {
    final t = svc.debugTracksFrom({
      'songs': [
        {'song': 'Tum Hi Ho', 'singers': 'Arijit Singh'},
      ],
    });
    expect(t.single.title, 'Tum Hi Ho');
    expect(t.single.artist, 'Arijit Singh');
  });

  test('tracks: v4 list with artistMap and &quot; entity', () {
    final t = svc.debugTracksFrom({
      'list': [
        {
          'title': 'Kesariya &quot;Live&quot;',
          'subtitle': 'Pritam, Arijit Singh - Brahmastra',
          'more_info': {
            'artistMap': {
              'primary_artists': [
                {'name': 'Pritam'},
                {'name': 'Arijit Singh'},
              ],
            },
          },
        },
        {'title': 'Only Subtitle', 'subtitle': 'Singer A - Some Album'},
      ],
    });
    expect(t[0].title, 'Kesariya "Live"');
    expect(t[0].artist, 'Pritam, Arijit Singh');
    expect(t[1].artist, 'Singer A');
  });

  test('tracks: saavn.dev data.songs with artists.primary', () {
    final t = svc.debugTracksFrom({
      'data': {
        'songs': [
          {
            'name': 'Song X',
            'artists': {
              'primary': [
                {'name': 'A'},
                {'name': 'B'},
              ],
            },
          },
        ],
      },
    });
    expect(t.single.title, 'Song X');
    expect(t.single.artist, 'A, B');
  });
}
