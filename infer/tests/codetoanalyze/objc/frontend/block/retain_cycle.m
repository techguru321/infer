/*
 * Copyright (c) 2015 - Facebook.
 * All rights reserved.
 */

#import <Foundation/NSObject.h>

@interface D : NSObject

@end


typedef void (^MyHandler)(D* data);


@interface B : NSObject

- (void)sHandler: (MyHandler) h;
@end

@implementation B {
    D* _d;
    MyHandler _h;
}

- (void)sHandler:(MyHandler)h {
    
    self->_h=h;
}

@end


@interface A : NSObject

- (void)capture;
@end

@implementation A {
    B* _b;
    D* _data;
}

- (void)capture
{
    _b=[B alloc];
    [_b sHandler:^(D *d){
        _data=d;
    }];
}

@end

A* foo(A* a) {
    
    [a capture];
    
    return a;
};


int main(int argc, const char * argv[]) {
    
    A* a = [A alloc];
    
    a=foo(a);
    
    return 0;
}
