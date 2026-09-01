<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{{LABEL}}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>{{START_CMD}}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>{{WORKDIR}}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>{{RUN_PATH}}</string>
{{ENV_ENTRIES}}
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>15</integer>
    <key>StandardOutPath</key>
    <string>{{OUT_LOG}}</string>
    <key>StandardErrorPath</key>
    <string>{{ERR_LOG}}</string>
</dict>
</plist>
