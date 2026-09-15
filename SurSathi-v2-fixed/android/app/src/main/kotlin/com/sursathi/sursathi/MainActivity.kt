package com.sursathi.sursathi

import com.ryanheise.audioservice.AudioServiceActivity

// audio_service ko background playback + notification/lock-screen controls
// ke liye MainActivity ko AudioServiceActivity extend karna zaroori hai.
// Iske bina AudioService.init() fail hota hai aur runApp() kabhi call hi
// nahi hota — yahi white-screen ka asli root cause tha.
class MainActivity : AudioServiceActivity()
