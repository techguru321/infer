/*
 * Copyright (c) 2013 - Facebook.
 * All rights reserved.
 */

typedef struct Point {
    int x;
    int y;
} Point;

int foo() {
    return 5;
}

int main() {
    struct Point p = {1, foo() + 3};
}

int test(Point *p) {
    *p = (Point){4, 5};
    return 0;
}

struct Employee
{
    int ssn;
    float salary;
    struct date
    {
        int date;
        int month;
        int year;
    }doj;
}emp1;

int main2() {
    struct Employee e = {12, 3000.50, 12, 12, 2010};
    return e.ssn;
}
