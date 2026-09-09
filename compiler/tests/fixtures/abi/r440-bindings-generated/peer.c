#include "exports.h"

#include <pthread.h>
#include <stdlib.h>

int binding_global_counter;

static const int binding_origin_source = 97;
const int *binding_saved_pointer = &binding_origin_source;

BindingView binding_borrow_view(const int *src)
{
    return (BindingView){ .data = src };
}

BindingNativeView binding_borrow_native(const int *src)
{
    return (BindingNativeView){ .data = src };
}

static const int *borrow_identity(const int *src)
{
    return src;
}

static int worker_status;
static int *worker_tls_address;

BindingPair binding_adjust_pair(BindingPair value)
{
    value.real += 1.0;
    value.count += 1;
    return value;
}

BindingValue binding_rotate_value(BindingValue value)
{
    value.signed_value += 7;
    return value;
}

static int plus_three(int value)
{
    return value + 3;
}

int binding_call_optional(binding_callback action, int value)
{
    return action == 0 ? value - 1 : action(value);
}

binding_callback binding_select_callback(int which)
{
    return which == 0 ? 0 : plus_three;
}

const int *binding_borrowed_pointer(int *base)
{
    return *base == 0 ? 0 : base;
}

static void *tls_worker(void *unused)
{
    (void)unused;
    if (landin_r440_bindings_binding_tls_counter_read() != 0) {
        worker_status = 1;
        return 0;
    }
    landin_r440_bindings_binding_tls_counter_write(29);
    worker_tls_address = landin_r440_bindings_binding_tls_counter_address();
    worker_status =
        landin_r440_bindings_binding_tls_counter_read() == 29 ? 0 : 2;
    return 0;
}

_Static_assert(__builtin_offsetof(BindingMatrix, values[1][0]) == 12,
               "generated matrix must preserve the C row stride");
_Static_assert(__builtin_types_compatible_p(BindingSmall, unsigned int),
               "small nonnegative enum is unsigned, despite int enumerators");

BindingMatrix binding_adjust_matrix(BindingMatrix value)
{
    value.values[0][2] += 30;
    value.values[1][0] += 40;
    value.values[1][2] += 60;
    return value;
}

BindingSmall binding_highbit(void)
{
    return (BindingSmall)0x80000000U;
}

int main(void)
{
    BindingMatrix matrix = { .values = {{1, 2, 3}, {4, 5, 6}} };
    BindingMatrix changed = landin_binding_matrix(matrix);
    if (changed.values[0][0] != 1 || changed.values[0][1] != 2 ||
        changed.values[0][2] != 33 || changed.values[1][0] != 44 ||
        changed.values[1][1] != 5 || changed.values[1][2] != 66) {
        return 21;
    }
    if (landin_binding_highbit((BindingSmall)0xffffffffU) != 4294967295UL) {
        return 22;
    }
    BindingView borrowed = { .tag = 0 };
    const int *borrow_result = &binding_global_counter;
    void *borrow_cell =
        landin_r440_bindings_binding_borrow_callback_cell_allocate();
    if (borrow_cell == 0) {
        return 23;
    }
    /* Absent callback leaves its output untouched, but the other two stores
       still run. The source has static duration as the Landin signature asks. */
    if (landin_binding_origins(&borrowed, borrow_cell, &borrow_result,
                               &binding_origin_source) ||
        borrow_result != &binding_global_counter ||
        borrowed.data != &binding_origin_source ||
        binding_saved_pointer != &binding_origin_source) {
        return 24;
    }
    landin_r440_bindings_binding_borrow_callback_cell_set(
        borrow_cell, borrow_identity);
    borrowed.tag = 0;
    binding_saved_pointer = &binding_global_counter;
    if (!landin_binding_origins(&borrowed, borrow_cell, &borrow_result,
                                &binding_origin_source) ||
        borrowed.data != &binding_origin_source ||
        borrow_result != &binding_origin_source ||
        binding_saved_pointer != &binding_origin_source || *borrow_result != 97) {
        return 25;
    }
    landin_r440_bindings_binding_borrow_callback_cell_release(borrow_cell);

    int landin_status = landin_bindings_check();
    if (landin_status != 42) {
        return landin_status;
    }
    if (binding_global_counter != 31 ||
        *landin_r440_bindings_binding_global_counter_address() != 31) {
        return 7;
    }
    landin_r440_bindings_binding_global_counter_write(32);
    if (landin_r440_bindings_binding_global_counter_read() != 32) {
        return 8;
    }

    void *value = landin_r440_bindings_binding_value_allocate();
    void *other = landin_r440_bindings_binding_value_allocate();
    if (value == 0 || other == 0 ||
        landin_r440_bindings_binding_value_size() != sizeof(BindingValue) ||
        landin_r440_bindings_binding_value_alignment() != _Alignof(BindingValue)) {
        return 9;
    }
    landin_r440_bindings_binding_value_signed_value_set(value, 11);
    landin_r440_bindings_binding_value_copy(other, value);
    if (landin_r440_bindings_binding_value_signed_value_get(other) != 11) {
        return 10;
    }
    landin_r440_bindings_binding_rotate_value_call(other, value);
    if (landin_r440_bindings_binding_value_signed_value_get(other) != 18) {
        return 11;
    }
    landin_r440_bindings_binding_value_release(other);
    landin_r440_bindings_binding_value_release(value);

    void *bits = landin_r440_bindings_binding_bits_allocate();
    if (bits == 0 ||
        landin_r440_bindings_binding_bits_size() != sizeof(BindingBits) ||
        landin_r440_bindings_binding_bits_alignment() != _Alignof(BindingBits)) {
        return 12;
    }
    landin_r440_bindings_binding_bits_neighbour_set(bits, 99);
    landin_r440_bindings_binding_bits_signed_bits_set(bits, -2);
    landin_r440_bindings_binding_bits_unsigned_bits_set(bits, 17U);
    if (landin_r440_bindings_binding_bits_signed_bits_get(bits) != -2 ||
        landin_r440_bindings_binding_bits_unsigned_bits_get(bits) != 17U ||
        landin_r440_bindings_binding_bits_neighbour_get(bits) != 99) {
        return 13;
    }
    landin_r440_bindings_binding_bits_release(bits);

    void *cell = landin_r440_bindings_binding_callback_cell_allocate();
    if (cell == 0 ||
        landin_r440_bindings_binding_callback_cell_present(cell)) {
        return 14;
    }
    int callback_result = 123;
    if (landin_r440_bindings_binding_callback_cell_invoke(
            cell, 8, &callback_result) || callback_result != 123 ||
        landin_r440_bindings_binding_call_optional_call(cell, 10) != 9) {
        return 15;
    }
    landin_r440_bindings_binding_callback_cell_set(cell, plus_three);
    if (!landin_r440_bindings_binding_callback_cell_present(cell) ||
        !landin_r440_bindings_binding_callback_cell_invoke(
            cell, 8, &callback_result) || callback_result != 11 ||
        landin_r440_bindings_binding_callback_cell_access(cell)(9) != 12 ||
        landin_r440_bindings_binding_call_optional_call(cell, 10) != 13) {
        return 16;
    }
    landin_r440_bindings_binding_callback_cell_clear(cell);
    landin_r440_bindings_binding_select_callback_call(cell, 1);
    if (!landin_r440_bindings_binding_callback_cell_present(cell) ||
        landin_r440_bindings_binding_callback_cell_access(cell)(10) != 13) {
        return 17;
    }
    landin_r440_bindings_binding_callback_cell_release(cell);

    int *main_tls_address =
        landin_r440_bindings_binding_tls_counter_address();
    if (*main_tls_address != 17) {
        return 18;
    }
    pthread_t thread;
    if (pthread_create(&thread, 0, tls_worker, 0) != 0 ||
        pthread_join(thread, 0) != 0 || worker_status != 0 ||
        worker_tls_address == main_tls_address ||
        landin_r440_bindings_binding_tls_counter_read() != 17) {
        return 19;
    }

    if (binding_receive_many(
            16, 1, 2, 3, 4,
            5.0, 6.0, 7.0, 8.0, 9.0,
            10.0, 11.0, 12.0, 13.0, 14.0,
            (long)15, (long)16) != 73) {
        return 20;
    }

    return landin_status;
}
