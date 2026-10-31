#import "LoveImporter.h"
#include "ZipExtract.h"

BOOL dc_extract_love_archive(NSString *loveFilePath, NSString *targetDirectory, NSError **error) {
    if (!loveFilePath || !targetDirectory) return NO;
    char reason[512] = {0};
    if (dc_zip_extract(loveFilePath.fileSystemRepresentation, targetDirectory.fileSystemRepresentation, reason, sizeof(reason)) != 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"LoveImporter" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:reason] ?: @"The archive couldn't be unpacked."}];
        }
        return NO;
    }
    return YES;
}
