/*
* Copyright (c) 2013 - present Facebook, Inc.
* All rights reserved.
*
* This source code is licensed under the BSD style license found in the
* LICENSE file in the root directory of this source tree. An additional grant
* of patent rights can be found in the PATENTS file in the same directory.
*/

int foo()
{
    int x=5;
    if (3 < 4 || 7<(x++)) { x=0;};
    int y =19;
    int n = ((3 < 4 || 7<((x++)-y )) ? 1 : 2);
     n = (2 < 1 ? 1 : (5>4 ? 1:2));
    return (0 + (7 > 9 ? 1 : 0));
 
}

int bar() {
    int x,y;
    y=(x=1) > 1 ? (++x) : (x--);
    return (0 + ( (3>4 ? 1:2) > 1 ? (x=1) : 0));
}
