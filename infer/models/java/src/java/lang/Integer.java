package java.lang;

public final class Integer {

  public static int MAX_VALUE = 2147483647; // 2**31-1
  public static int MIN_VALUE = -2147483648; // -2**31

  protected final int value;

  public Integer(int i) {
    this.value = i;
  }

  public static Integer valueOf(int i) {
    return new Integer(i);
  }

  public boolean equals(Object anObject) {
    return anObject != null
      && anObject instanceof Integer
      && this.value == ((Integer) anObject).value;
  }

  public int intValue() {
    return this.value;
  }

}
