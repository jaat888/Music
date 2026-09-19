// lib/widgets/radio_swipe_stage.dart
//
// Reels/YouTube-Shorts jaisa REAL swipe stage for Radio mode.
//
// Pehle Radio ka swipe sirf "release" pe fire hota tha — finger jab tak
// screen pe hai, kuch bhi move nahi hota tha, aur jab uthta tha to seedha
// agla gaana ek chhoti si (0.12 offset) crossfade ke saath aa jaata tha.
// Ye widget uske jagah asli "finger ke saath live-follow" swipe deta hai:
//
//  - Jaise hi finger neeche/upar drag hota hai, poori screen usi ke saath
//    real-time move karti hai (jaisa Reels/Shorts mein hota hai).
//  - Agar agla/pichla gaana pehle se pata hai (Radio ka `_upcoming` /
//    `_playedStack` — jo already prefetch/artwork-cached hote hain), to
//    uska halka preview turant peeking-in dikhta hai, load hone ka wait
//    nahi karna padta.
//  - Threshold cross na ho (halka sa hi khinch ke chhod diya) to spring-back
//    ho jaata hai, koi navigation nahi hoti.
//  - Threshold cross ho jaaye to turant snap-through ho jaata hai aur
//    `onCommitNext`/`onCommitPrevious` fire hota hai — asli Radio-advance
//    logic (network/audio) wahi purana hai, isse chheda nahi gaya.
//
// IMPORTANT: jab commit ho jaata hai, ye widget peek-page ko poori screen
// par "parked" rakhta hai jab tak asli `contentId` (parent se) badal na
// jaaye — taaki asli gaana load hone se PEHLE hi purana gaana wapas na
// dikh jaaye (ulta flash). Jaise hi parent ka `current` naye gaane pe
// switch hota hai (contentId change), drag silently 0 pe reset ho jaata
// hai — dono frames identical dikhte hain isliye ye switch bilkul
// invisible hota hai (koi jump nahi).
import 'dart:async';

import 'package:flutter/material.dart';

class RadioSwipeStage extends StatefulWidget {
  /// Currently-playing candidate ki unique id (song id). Isi se pata
  /// chalta hai ki asli content kab badla (taaki parked peek ko drop
  /// karke silently uspe switch kiya ja sake).
  final Object contentId;

  /// Poori tarah bana hua "current" page — artwork + top bar + lyrics +
  /// timeline + controls, sab kuch (jo pehle seedha Scaffold body mein
  /// jaata tha).
  final Widget current;

  /// Halka preview page agle gaane ka (sirf artwork+title+artist) — null
  /// agar agla gaana abhi pata nahi (is case mein upar-swipe rubber-band
  /// karega, navigate nahi karega).
  final Widget? peekNext;

  /// Halka preview page pichle gaane ka, same rules jaisa [peekNext].
  final Widget? peekPrevious;

  /// Agla gaana available hai kya (typically `_upcoming.isNotEmpty`).
  final bool canGoNext;

  /// Pichla gaana available hai kya (typically `_playedStack.isNotEmpty`).
  final bool canGoPrevious;

  final VoidCallback onCommitNext;
  final VoidCallback onCommitPrevious;

  const RadioSwipeStage({
    super.key,
    required this.contentId,
    required this.current,
    required this.peekNext,
    required this.peekPrevious,
    required this.canGoNext,
    required this.canGoPrevious,
    required this.onCommitNext,
    required this.onCommitPrevious,
  });

  @override
  State<RadioSwipeStage> createState() => _RadioSwipeStageState();
}

class _RadioSwipeStageState extends State<RadioSwipeStage>
    with SingleTickerProviderStateMixin {
  // -1 (poora upar/next tak khinch gaya) .. 0 (neutral) .. +1 (poora
  // neeche/previous tak khinch gaya) — screen-height ka fraction.
  double _drag = 0;
  double _height = 0;
  late final AnimationController _controller;
  Animation<double>? _settleAnim;

  // Jab commit ho chuka ho (screen poori tarah "next"/"previous" peek se
  // dhak chuki ho) lekin asli `contentId` abhi tak update nahi hua —
  // is dauraan naya drag shuru nahi hone dete (spam-proof), aur
  // `didUpdateWidget` isi flag ko dekh ke silent-reset karta hai.
  int _pendingCommit = 0; // -1 next, 0 none, +1 previous
  Timer? _pendingTimeout;
  // Commit hote hi jo peek dikh raha tha wahi FREEZE kar dete hain. Warna
  // parked state ke dauraan parent ke `_upcoming`/`_playedStack` aage
  // mutate hote rehte hain (asli `_advance()`/`_previous()` chal rahe
  // hote hain) — agar hum live `widget.peekNext`/`peekPrevious` padhte
  // rahte, to parked screen beech mein hi ek ALAG (agle wale) preview par
  // achanak badal jaati, asli switch se pehle hi — jaisa jitter/flash.
  Widget? _frozenPeek;

  static const _commitFraction = 0.22; // ~22% screen height khinchne pe commit
  static const _commitVelocity = 900.0; // ya itni fast fling pe commit (px/s)
  // SAFETY VALVE: agar asli navigation (network/audio) is dauraan hi fail
  // ho jaaye (12 attempts, error state) to `contentId` kabhi nahi badlega
  // — bina is timeout ke screen hamesha ke liye peek-page par "stuck" reh
  // jaati, aur neeche wala asli error kabhi dikhta hi nahi. Itni der mein
  // koi switch na ho to parked peek chhodke wapas asli (error-wale)
  // current par revert kar do.
  static const _pendingSafetyTimeout = Duration(seconds: 9);

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
  }

  @override
  void didUpdateWidget(covariant RadioSwipeStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Asli content aa gaya jiska hum wait kar rahe the — parked peek ko
    // "current" mein invisible-swap kar do (dono ek jaise dikh rahe hote
    // hain, isliye jump nahi dikhta).
    if (_pendingCommit != 0 && widget.contentId != oldWidget.contentId) {
      _resolvePending(resetDragInstantly: true);
    }
  }

  @override
  void dispose() {
    _pendingTimeout?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// Parked peek se nikal ke wapas neutral par le aata hai. Naya content
  /// aa chuka ho to `resetDragInstantly=true` (invisible swap — dono
  /// frames identical dikhte hain), safety-timeout ke case mein
  /// `resetDragInstantly=false` (halka spring-back animation, kyunki
  /// yahan asli content abhi bhi wahi purana hai jo drag se pehle tha).
  void _resolvePending({required bool resetDragInstantly}) {
    _pendingTimeout?.cancel();
    _pendingTimeout = null;
    _settleAnim = null;
    _controller.stop();
    if (resetDragInstantly) {
      setState(() {
        _drag = 0;
        _pendingCommit = 0;
        _frozenPeek = null;
      });
    } else {
      setState(() {
        _pendingCommit = 0;
        _frozenPeek = null;
      });
      _animateTo(0, curve: Curves.easeOutCubic);
    }
  }

  void _onDragStart(DragStartDetails d) {
    // Ek commit "parked" hote hue beech mein doosra drag shuru na hone
    // do — jab tak asli switch (ya safety-timeout revert) na ho jaaye.
    if (_pendingCommit != 0) return;
    if (_controller.isAnimating) _controller.stop();
    _settleAnim = null;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (_pendingCommit != 0 || _height <= 0) return;
    final delta = (d.primaryDelta ?? 0) / _height;
    var next = _drag + delta;
    final goingUp = delta < 0; // finger upar → agla gaana chahiye
    // Us taraf koi candidate hi na ho to rubber-band jaisa halka
    // resistance — poori tarah rigid/dead nahi, thoda "give" mehsoos ho.
    if (goingUp && !widget.canGoNext) {
      next = _drag + delta * 0.30;
    } else if (!goingUp && !widget.canGoPrevious) {
      next = _drag + delta * 0.30;
    }
    setState(() => _drag = next.clamp(-1.0, 1.0));
  }

  void _onDragEnd(DragEndDetails d) {
    if (_pendingCommit != 0) return;
    final velocity = d.primaryVelocity ?? 0;
    final wantNext = _drag < -_commitFraction ||
        (velocity < -_commitVelocity && _drag < -0.02);
    final wantPrevious = _drag > _commitFraction ||
        (velocity > _commitVelocity && _drag > 0.02);

    if (wantNext && widget.canGoNext) {
      _commit(direction: -1, onFire: widget.onCommitNext);
    } else if (wantPrevious && widget.canGoPrevious) {
      _commit(direction: 1, onFire: widget.onCommitPrevious);
    } else {
      _springBack();
    }
  }

  void _commit({required int direction, required VoidCallback onFire}) {
    // Peek ko freeze karo (parent ke `_upcoming`/`_playedStack` mutate
    // hone se pehle hi) — dekho `_frozenPeek` field ka comment.
    final frozen = direction == -1 ? widget.peekNext : widget.peekPrevious;
    // Asli navigation TURANT fire karo (jaisa pehle onVerticalDragEnd
    // mein hota tha) — animation ke saath parallel mein load shuru ho
    // jaaye, taaki perceived latency kam se kam rahe.
    onFire();
    setState(() {
      _pendingCommit = direction;
      _frozenPeek = frozen;
    });
    _animateTo(direction.toDouble(), curve: Curves.easeOutCubic);
    _pendingTimeout?.cancel();
    _pendingTimeout = Timer(_pendingSafetyTimeout, () {
      if (!mounted || _pendingCommit == 0) return;
      _resolvePending(resetDragInstantly: false);
    });
  }

  void _springBack() {
    _animateTo(0, curve: Curves.easeOutCubic);
  }

  void _animateTo(double target, {required Curve curve}) {
    _controller
      ..stop()
      ..reset();
    final anim = Tween<double>(begin: _drag, end: target).animate(
      CurvedAnimation(parent: _controller, curve: curve),
    );
    _settleAnim = anim;
    void tick() {
      if (!mounted || _settleAnim != anim) return;
      setState(() => _drag = anim.value);
    }

    anim.addListener(tick);
    _controller.forward().whenCompleteOrCancel(() {
      anim.removeListener(tick);
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _height = constraints.maxHeight;
        final dy = _drag * _height;
        // Halka "depth" feel — jitna khincho, current utna hi thoda
        // chhota/dim hota hai (Reels/Shorts jaisa card-lift effect).
        final depth = _drag.abs().clamp(0.0, 1.0);
        final currentScale = 1.0 - (depth * 0.05);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: _onDragStart,
          onVerticalDragUpdate: _onDragUpdate,
          onVerticalDragEnd: _onDragEnd,
          child: ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_drag < 0 &&
                    (_pendingCommit == -1 ? _frozenPeek : widget.peekNext) !=
                        null)
                  Transform.translate(
                    offset: Offset(0, _height + dy),
                    child: _pendingCommit == -1
                        ? _frozenPeek
                        : widget.peekNext,
                  ),
                if (_drag > 0 &&
                    (_pendingCommit == 1 ? _frozenPeek : widget.peekPrevious) !=
                        null)
                  Transform.translate(
                    offset: Offset(0, -_height + dy),
                    child: _pendingCommit == 1
                        ? _frozenPeek
                        : widget.peekPrevious,
                  ),
                Transform.translate(
                  offset: Offset(0, dy),
                  child: Transform.scale(
                    scale: currentScale,
                    child: widget.current,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
