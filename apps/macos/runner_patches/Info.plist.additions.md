# Info.plist 需要加的键

打开 `macos/Runner/Info.plist`,在最外层 `<dict>` 里加入下面这一对键值,
让 App 成为**菜单栏专属(无 Dock 图标)**:

```xml
	<key>LSUIElement</key>
	<true/>
```

> 说明:`LSUIElement=true` 等价于 accessory 应用 —— 不在 Dock 显示、不抢占菜单栏,
> 只在系统状态栏放一个图标/标题。这正是"快速预览栏"想要的形态。

其余键保持 flutter create 生成的默认值即可。
