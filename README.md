
# How to build your own Linux Claude Desktop
1. open chat claude.ai (better to use Pro, Max or Team)
2. copy/paste prompt.txt content
3. Claude will generate your script build-claude-desktop.sh (my version is included in this repo, just in case: you should generate your own)
4. make the generated script executable
5. run it
6. it will generate your package
7. install your package
8. run your Claude Desktop

```chmod +x build-claude-desktop.sh
./build-claude-desktop.sh
sudo dpkg -i claude-desktop_*.deb
sudo apt-get install -f
claude-desktop
```

If you encounter problem, interact with Claude, in order to solve it.

Keep me informed of problems with a comment at

https://www.linkedin.com/posts/vincenzo-caselli_ugcPost-7452501572623712256-NxH1?utm_source=share&utm_medium=member_desktop&rcm=ACoAAAEd7dkB5lZQ8ueQpuWRxNcpsjN6o2k6zzE

# In case of freeze/hung
```
# kill all Claude Desktop processes
pkill -f claude-desktop
pkill -f electron

# Remove lock file
rm -f ~/.config/Claude/IndexedDB/https_claude.ai_0.indexeddb.leveldb/LOCK

# Re-launch
claude-desktop
```

# How to verify Claude Desktop latest version
```
curl -sL "https://downloads.claude.ai/releases/win32/x64/RELEASES"
```
