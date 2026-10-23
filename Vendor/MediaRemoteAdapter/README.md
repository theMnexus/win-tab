# MediaRemoteAdapter (vendored)

From https://github.com/ungive/mediaremote-adapter (BSD 3-Clause, see LICENSE),
commit 73f14ab1568371e6e3c44063f21c34c5e2712c4d. Lets win-tab read and control whatever
is playing (Chrome/YouTube, Safari, Spotify, Music…) on macOS 15.4+, where MediaRemote is
closed to third-party apps: `/usr/bin/perl` is entitled to use it and loads this framework.

Bundled into the app's Resources, never linked. Rebuild:

    git clone https://github.com/ungive/mediaremote-adapter && cd mediaremote-adapter
    git checkout 73f14ab1568371e6e3c44063f21c34c5e2712c4d
    mkdir build && cd build && cmake .. && cmake --build .
    # copy build/MediaRemoteAdapter.framework and bin/mediaremote-adapter.pl here
