#include <stdio.h>
#include <stdlib.h>

int *set42(int* x) {
    
    *x=42;
    return x;
}

void nodpd () {
    
    int w,z;
    
    z=set42(&w);
    
}

void nodpd1 () {
    
    int *y =  malloc(sizeof(int));
    int *z;
    z=set42(y);
    free(y);
    
}



void dpd () {
    
    int *y;
    int *z;
    z=set42(y);
}


void intraprocdpd () {
    
    int *y;
    int *z;
    *y=42;
    z=y;
}
