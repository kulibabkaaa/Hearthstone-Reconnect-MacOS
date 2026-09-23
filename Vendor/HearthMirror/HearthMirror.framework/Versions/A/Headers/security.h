//
//  security.h
//  HearthMirror
//
//  Created by Istvan Fehervari on 26/12/2016.
//  Copyright © 2016 com.ifehervari. All rights reserved.
//

#ifndef security_h
#define security_h

#define EXPORT __attribute__((visibility("default")))

#ifdef __APPLE__

#ifdef __cplusplus
extern "C" {
#endif
    
/** Requests access to attach to another process. Required for HearthMirror to function properly. */
int EXPORT acquireTaskportRight(void);

#ifdef __cplusplus
}
#endif // extern "C"

#endif // __APPLE__

#endif /* security_h */
