#ifndef R440_BINDINGS_H
#define R440_BINDINGS_H

typedef struct BindingPair {
    double real;
    int count;
} BindingPair;

typedef enum BindingMode {
    BINDING_MODE_NEGATIVE = -1,
    BINDING_MODE_ZERO = 0,
    BINDING_MODE_ALIAS = 0,
    BINDING_MODE_LARGE = 4000000000U
} BindingMode;

typedef union BindingValue {
    int signed_value;
    double real_value;
} BindingValue;

typedef struct BindingBits {
    signed int signed_bits : 3;
    unsigned int : 0;
    unsigned int unsigned_bits : 5;
    int neighbour;
} BindingBits;

typedef int (*binding_callback)(int value);

extern BindingPair binding_adjust_pair(BindingPair value);
extern BindingValue binding_rotate_value(BindingValue value);
extern int binding_call_optional(binding_callback action, int value);
extern binding_callback binding_select_callback(int which);
extern const int *binding_borrowed_pointer(int *base);
extern int binding_global_counter;
extern _Thread_local int binding_tls_counter;
extern int binding_receive_many(int count, ...);

typedef struct BindingMatrix {
    int values[2][3];
} BindingMatrix;

typedef enum BindingSmall {
    BINDING_SMALL_ZERO = 0,
    BINDING_SMALL_ONE = 1
} BindingSmall;

extern BindingMatrix binding_adjust_matrix(BindingMatrix value);
extern BindingMatrix landin_binding_matrix(BindingMatrix value);
extern BindingSmall binding_highbit(void);
extern unsigned long landin_binding_highbit(BindingSmall value);

typedef union BindingView {
    const int *data;
    int tag;
} BindingView;

typedef struct BindingNativeView {
    const int *data;
} BindingNativeView;

typedef const int *binding_int_pointer;
typedef const int *(*binding_borrow_callback)(const int *);
extern BindingView binding_borrow_view(const int *src);
extern BindingNativeView binding_borrow_native(const int *src);
extern const int *binding_saved_pointer;
extern _Bool landin_binding_origins(void *output, const void *cell,
                                   binding_int_pointer *result_pointer, const int *src);

extern int landin_bindings_check(void);

#endif
