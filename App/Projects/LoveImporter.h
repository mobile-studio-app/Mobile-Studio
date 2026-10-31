#ifndef DUO_LOVE_IMPORTER_H
#define DUO_LOVE_IMPORTER_H

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Extracts a .love file (standard zip archive) into target directory.
/// Returns YES on success, NO on error.
BOOL dc_extract_love_archive(NSString *loveFilePath, NSString *targetDirectory, NSError **error);

#ifdef __cplusplus
}
#endif

#endif /* DUO_LOVE_IMPORTER_H */

