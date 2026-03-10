#import <Cocoa/Cocoa.h>
#include <stdlib.h>
#include <string.h>

// 嵌入 Info.plist 到二进制，禁用 macOS AutoFill 辅助进程（macOS Tahoe 已知问题）
__attribute__((used, section("__TEXT,__info_plist")))
static const char embedded_info_plist[] =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
    "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
    "<plist version=\"1.0\">\n"
    "<dict>\n"
    "    <key>CFBundleIdentifier</key>\n"
    "    <string>com.zscripts.app</string>\n"
    "    <key>CFBundleName</key>\n"
    "    <string>zScripts</string>\n"
    "    <key>NSAutoFillRequiresTextContentTypeForOneTimeCodeOnMac</key>\n"
    "    <true/>\n"
    "</dict>\n"
    "</plist>\n";

// 显示文件选择对话框
char** showOpenPanel(bool allowFiles, bool allowDirectories, bool allowMultiple, const char** fileTypes, int fileTypesCount) {
    @autoreleasepool {
        NSOpenPanel* panel = [NSOpenPanel openPanel];

        // 设置选项
        [panel setCanChooseFiles:allowFiles];
        [panel setCanChooseDirectories:allowDirectories];
        [panel setAllowsMultipleSelection:allowMultiple];

        // 设置文件类型过滤
        if (allowFiles && fileTypes != NULL && fileTypesCount > 0) {
            NSMutableArray* types = [NSMutableArray arrayWithCapacity:fileTypesCount];
            for (int i = 0; i < fileTypesCount; i++) {
                [types addObject:[NSString stringWithUTF8String:fileTypes[i]]];
            }
            [panel setAllowedFileTypes:types];
        }

        // 显示对话框
        NSModalResponse response = [panel runModal];

        if (response == NSModalResponseOK) {
            NSArray* urls = [panel URLs];
            NSUInteger count = [urls count];

            if (count == 0) {
                return NULL;
            }

            // 分配路径数组（多一个位置存储数量）
            char** paths = (char**)malloc(sizeof(char*) * (count + 1));
            paths[0] = (char*)(uintptr_t)count; // 第一个元素存储数量

            for (NSUInteger i = 0; i < count; i++) {
                NSURL* url = urls[i];
                const char* path = [[url path] UTF8String];
                paths[i + 1] = strdup(path);
            }

            return paths;
        }

        return NULL;
    }
}

// 获取路径数组的数量
int getPathArrayCount(char** paths) {
    if (paths == NULL) {
        return 0;
    }
    return (int)(uintptr_t)paths[0];
}

// 释放路径数组
void freePathArray(char** paths, int count) {
    if (paths == NULL) {
        return;
    }

    for (int i = 1; i <= count; i++) {
        free(paths[i]);
    }
    free(paths);
}
