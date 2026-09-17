// lib/services/equalizer_presets.dart
// PART 2 (EQ presets): band frequencies + preset curves — ek hi jagah
// define hote hain taaki UI (equalizer_screen.dart) aur asli DSP apply
// (background_service.dart, AndroidEqualizer ke through) kabhi bhi
// mismatch na ho (pehle ye list sirf equalizer_screen.dart ke andar thi
// aur wahan se kabhi actual audio ko touch hi nahi karti thi — dekho us
// file ka purana top-comment: "filhaal sirf UI + SharedPreferences save
// hai, functional audio effect optional rakha gaya").
//
// NOTE: Yahan diye 10 bands ek "conceptual" curve hain (20Hz-20kHz).
// Real Android device ka `AndroidEqualizer` hardware/driver ke hisaab se
// alag hi band-count/frequencies expose karta hai (aam taur pe 5-6 bands)
// — background_service.dart runtime pe in dono ko log-frequency
// interpolation se map karta hai, isliye UI yahan hamesha same 10 fixed
// bands dikha sakta hai chahe device ka asli EQ kuch bhi ho.
const List<int> kEqualizerBandFreqs = [
  20,
  60,
  150,
  400,
  1000,
  2400,
  6000,
  12000,
  16000,
  20000,
];

const Map<String, List<double>> kEqualizerPresets = {
  'Flat': [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  'Rock': [4, 4, 3, -2, -4, -2, 2, 5, 6, 6],
  'Pop': [-1, -1, 2, 4, 4, 1, -1, -2, -2, 1],
  'Jazz': [3, 3, 2, 1, 2, -2, -2, 0, 2, 3],
  'Classical': [4, 4, 3, 2, 0, 0, 0, -2, -2, -3],
  'Bass': [7, 7, 6, 5, 3, 1, -1, -2, -3, -3],
  'Treble': [-3, -3, -3, -2, -1, 0, 2, 4, 5, 6],
  'Vocal': [-2, -2, -3, -2, 1, 4, 5, 4, 2, 0],
  'Dance': [5, 5, 4, 2, 0, -2, -1, 0, 2, 3],
  'Hip-Hop': [6, 6, 5, 3, 1, -1, -1, 1, 2, 2],
  'Acoustic': [3, 3, 3, 2, 1, 0, 1, 2, 2, 3],
  'Custom': [],
};
