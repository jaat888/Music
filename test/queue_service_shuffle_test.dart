// test/queue_service_shuffle_test.dart
//
// v106: Shuffle pehle sirf ek flag tha (`_shuffleOrder` bani thi lekin
// next()/previous()/upcoming kahin use nahi karte the). Ye tests
// guarantee karte hain ki ab shuffle ON mein play order `_shuffleOrder` se
// chalta hai, aur shuffle OFF ka purana linear behavior bilkul waisa hi hai.
//
// Chalane ke liye: `flutter test test/queue_service_shuffle_test.dart`

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sursathi/models/song.dart';
import 'package:sursathi/services/queue_service.dart';

Song _song(int i) => Song(
      id: 's$i',
      title: 'Song $i',
      artist: 'Artist',
      thumb: '',
      duration: 180,
    );

QueueService _queue(int n, {int seed = 1, int start = 0}) {
  final q = QueueService.forTesting(random: Random(seed));
  q.setQueue(List<Song>.generate(n, _song), startIndex: start);
  return q;
}

/// Current se shuru karke end tak `next()` chalao, visited queue indices do.
List<int> _walkForward(QueueService q) {
  final seen = <int>[q.currentIndex];
  while (!q.isLastInPlayOrder) {
    q.next();
    seen.add(q.currentIndex);
  }
  return seen;
}

void main() {
  group('QueueService — shuffle OFF (purana behavior)', () {
    test('next/previous linear chalte hain', () {
      final q = _queue(4);
      q.next();
      expect(q.currentIndex, 1);
      q.next();
      q.next();
      expect(q.currentIndex, 3);
      expect(q.isLastInPlayOrder, isTrue);
      q.next(); // repeat off + aakhri gaana => index wahi
      expect(q.currentIndex, 3);
      q.previous();
      expect(q.currentIndex, 2);
    });

    test('upcoming + upcomingIndices physical order mein', () {
      final q = _queue(5, start: 1);
      expect(q.upcomingIndices, [2, 3, 4]);
      expect(q.upcoming.map((s) => s.id), ['s2', 's3', 's4']);
    });

    test('repeat all: aakhri se 0 pe wapas', () {
      final q = _queue(3, start: 2);
      q.setRepeat(SurRepeatMode.all);
      q.next();
      expect(q.currentIndex, 0);
      q.previous();
      expect(q.currentIndex, 2);
    });
  });

  group('QueueService — shuffle ON', () {
    test('ek poora pass har gaana EXACTLY ek baar, current se shuru', () {
      for (var seed = 0; seed < 25; seed++) {
        final q = _queue(9, seed: seed, start: seed % 9);
        final start = q.currentIndex;
        q.setShuffle(true);
        expect(q.currentIndex, start, reason: 'toggle pe current nahi badalna chahiye');
        final seen = _walkForward(q);
        expect(seen.first, start);
        expect(seen.length, 9);
        expect(seen.toSet().length, 9);
      }
    });

    test('order asli mein shuffled hai (linear nahi)', () {
      var differsFromLinear = false;
      for (var seed = 0; seed < 10; seed++) {
        final q = _queue(12, seed: seed);
        q.setShuffle(true);
        final seen = _walkForward(q);
        if (seen.join(',') != List<int>.generate(12, (i) => i).join(',')) {
          differsFromLinear = true;
        }
      }
      expect(differsFromLinear, isTrue);
    });

    test('previous() play order mein bilkul ulta chalta hai', () {
      final q = _queue(8, seed: 3);
      q.setShuffle(true);
      final forward = _walkForward(q);
      final back = <int>[q.currentIndex];
      while (true) {
        final before = q.currentIndex;
        q.previous();
        if (q.currentIndex == before) break;
        back.add(q.currentIndex);
      }
      expect(back, forward.reversed.toList());
    });

    test('upcoming/upcomingIndices play order ko follow karte hain', () {
      final q = _queue(7, seed: 5);
      q.setShuffle(true);
      final expectedUpcoming = q.upcomingIndices;
      expect(expectedUpcoming.length, 6);
      q.next();
      expect(q.currentIndex, expectedUpcoming.first);
      expect(q.upcomingIndices, expectedUpcoming.sublist(1));
      expect(
        q.upcoming.map((s) => s.id).toList(),
        q.upcomingIndices.map((i) => 's$i').toList(),
      );
    });

    test('shuffle OFF karne par current wahin rehta hai, linear chalta hai', () {
      final q = _queue(6, seed: 2);
      q.setShuffle(true);
      q.next();
      q.next();
      final cur = q.currentIndex;
      q.setShuffle(false);
      expect(q.currentIndex, cur);
      if (cur < 5) {
        q.next();
        expect(q.currentIndex, cur + 1);
      }
    });

    test('repeat off: order ke end pe next() ruk jaata hai', () {
      final q = _queue(4, seed: 4);
      q.setShuffle(true);
      _walkForward(q);
      final last = q.currentIndex;
      expect(q.isLastInPlayOrder, isTrue);
      q.next();
      expect(q.currentIndex, last);
    });

    test('repeat all: naya cycle, jo gaana abhi khatam hua wahi pehle nahi', () {
      for (var seed = 0; seed < 30; seed++) {
        final q = _queue(5, seed: seed);
        q.setShuffle(true);
        q.setRepeat(SurRepeatMode.all);
        _walkForward(q);
        final finished = q.currentIndex;
        q.next();
        expect(q.currentIndex, isNot(finished));
        // naya cycle bhi poora pass hai
        final seen = _walkForward(q);
        expect(seen.toSet().length, 5);
      }
    });

    test('repeat one: next() index nahi badalta', () {
      final q = _queue(5);
      q.setShuffle(true);
      q.setRepeat(SurRepeatMode.one);
      final cur = q.currentIndex;
      q.next();
      expect(q.currentIndex, cur);
    });

    test('jumpTo ke baad previous() us gaane pe jaata hai jo abhi baj raha tha', () {
      for (var seed = 0; seed < 25; seed++) {
        final q = _queue(8, seed: seed);
        q.setShuffle(true);
        q.next();
        final before = q.currentIndex;
        final target = q.upcomingIndices.last; // Up Next me door wala
        q.jumpTo(target);
        expect(q.currentIndex, target);
        q.previous();
        expect(q.currentIndex, before);
      }
    });

    test('removeAt play order + current ko consistent rakhta hai', () {
      final q = _queue(6, seed: 9);
      q.setShuffle(true);
      q.next();
      final currentId = q.currentSong!.id;
      final toRemove = q.upcomingIndices[1];
      final removedId = q.queue[toRemove].id;
      final upcomingBefore =
          q.upcoming.map((s) => s.id).where((id) => id != removedId).toList();
      q.removeAt(toRemove);
      expect(q.currentSong!.id, currentId);
      expect(q.upcoming.map((s) => s.id).toList(), upcomingBefore);
      expect(q.queue.length, 5);
    });

    test('removeAt(current) shuffle mein play order ka agla gaana current banata hai', () {
      final q = _queue(6, seed: 11);
      q.setShuffle(true);
      final nextId = q.upcoming.first.id;
      q.removeAt(q.currentIndex);
      expect(q.currentSong!.id, nextId);
    });

    test('add() Up Next ko reshuffle nahi karta, naya gaana end mein aata hai', () {
      final q = _queue(5, seed: 6);
      q.setShuffle(true);
      final before = q.upcoming.map((s) => s.id).toList();
      q.add(_song(99));
      final after = q.upcoming.map((s) => s.id).toList();
      expect(after.sublist(0, before.length), before);
      expect(after.last, 's99');
    });

    test('physical reorder() play order ko nahi badalta', () {
      final q = _queue(6, seed: 8);
      q.setShuffle(true);
      final idsBefore = q.upcoming.map((s) => s.id).toList();
      final currentId = q.currentSong!.id;
      q.reorder(0, 4); // physical queue me move
      expect(q.currentSong!.id, currentId);
      expect(q.upcoming.map((s) => s.id).toList(), idsBefore);
    });

    test('reorderUpcoming shuffle mein sirf play order badalta hai', () {
      final q = _queue(6, seed: 12);
      q.setShuffle(true);
      final ids = q.upcoming.map((s) => s.id).toList();
      final physicalBefore = q.queue.map((s) => s.id).toList();
      q.reorderUpcoming(0, 3); // ReorderableListView convention: newIndex=3 => 2 pe
      final expected = [ids[1], ids[2], ids[0], ...ids.sublist(3)];
      expect(q.upcoming.map((s) => s.id).toList(), expected);
      expect(q.queue.map((s) => s.id).toList(), physicalBefore);
    });

    test('random ops ke baad bhi order permutation rehta hai', () {
      final rnd = Random(2024);
      final q = QueueService.forTesting(random: Random(77));
      q.setQueue(List<Song>.generate(6, _song), startIndex: 0);
      q.setShuffle(true);
      var nextId = 100;
      for (var step = 0; step < 400; step++) {
        switch (rnd.nextInt(7)) {
          case 0:
            q.add(_song(nextId++));
            break;
          case 1:
            if (q.queue.isNotEmpty) q.removeAt(rnd.nextInt(q.queue.length));
            break;
          case 2:
            q.next();
            break;
          case 3:
            q.previous();
            break;
          case 4:
            if (q.queue.isNotEmpty) q.jumpTo(rnd.nextInt(q.queue.length));
            break;
          case 5:
            if (q.queue.length > 1) {
              q.reorder(rnd.nextInt(q.queue.length), rnd.nextInt(q.queue.length + 1));
            }
            break;
          case 6:
            final n = q.upcoming.length;
            if (n > 1) q.reorderUpcoming(rnd.nextInt(n), rnd.nextInt(n + 1));
            break;
        }
        final order = q.shuffleOrderForTesting;
        if (q.queue.isNotEmpty) {
          expect(order.length, q.queue.length);
          expect(order.toSet().length, order.length);
          expect(order.every((i) => i >= 0 && i < q.queue.length), isTrue);
          expect(order.contains(q.currentIndex), isTrue);
        }
      }
    });
  });
}
