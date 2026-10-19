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

/* D410's byte-packed records and D413's flexible array member.  C reaches
   each only through a pointer (D414); the generator wraps the by-value
   forms below in pointer adapters. */
typedef struct __attribute__((packed)) BindingWire {
    unsigned char kind;
    unsigned short half;
    unsigned int word;
    unsigned long wide;
    double twice;
    _Bool flag;
    unsigned char bytes[3];
} BindingWire;

typedef struct __attribute__((packed)) BindingFrame {
    unsigned char lead;
    BindingWire body;
    unsigned short tail;
} BindingFrame;

typedef struct BindingEntry {
    unsigned long inode;
    unsigned short length;
    unsigned char kind;
    char name[];
} BindingEntry;

typedef struct __attribute__((packed)) BindingWords {
    unsigned char kind;
    unsigned int data[];
} BindingWords;

extern unsigned long binding_layout(int which);
extern void binding_wire_fill(BindingWire *record);
extern int binding_wire_check(const BindingWire *record);
extern BindingWire binding_wire_make(unsigned char kind);
extern int binding_frame_check(BindingFrame value);
extern void binding_entry_fill(BindingEntry *record);
extern int binding_entry_check(const BindingEntry *record);
extern int binding_words_sum(const BindingWords *record, int count);
extern BindingFrame binding_frame_global;
extern void landin_binding_wire_mark(BindingWire *record);

extern int landin_bindings_check(void);

#endif
