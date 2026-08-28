# Running examples

These are complete Landin programs that the bootstrap compiler accepts,
lowers, emits, links and runs today on Linux x86-64. They are the same sources
the runtime suite executes, and each returns 42 only after checking its result.

The current kernel has recursive functions [1800], fixed arrays [0520],
computed indexing [0570] and static array literals, but no loops or aggregate
parameters yet. The sorting examples therefore recurse over module-level
arrays. That is an honest picture of the implemented language today, not the
eventual library interface.

## Compile and run

After building `refine` and putting it on `PATH`, compile any source shown
below. For example:

```sh
refine --target=linux-x86-64 --emit=exe \
  -o /tmp/landin-fibonacci \
  compiler/tests/fixtures/runtime/recursive-fibonacci/main.ldn
/tmp/landin-fibonacci
test $? -eq 42
```

The programs print nothing. Status 42 means the checks in `main` passed; any
other returned status makes the runtime fixture fail. The authoritative Linux
gate builds and runs all four on every push.

## Recursive Fibonacci

The first complete kernel program calls itself twice per recursive step. Its
checks cover the base cases and enough calls to expose a broken call frame,
prologue or epilogue.

Fixture source: `compiler/tests/fixtures/runtime/recursive-fibonacci/main.ldn`.

```landin
--  The smallest program that is a program rather than a probe: a function
--  that calls itself twice, one call's result feeding an operator, over a
--  frame that has to survive both.  fib(25) makes 242785 calls and reaches
--  25 nested fib frames, 26 including main: enough to find a prologue or an
--  epilogue that only looked right.
fib: (n: u32) -> (r: u32) =
    r = n

    if n > 1 then
        r = fib(n - 1) + fib(n - 2)
    end if
end fib

public main: () -> (code: i32) =
    if fib(0) == 0
        and fib(1) == 1
        and fib(2) == 1
        and fib(10) == 55
        and fib(20) == 6765
        and fib(25) == 75025
    then
        code = 42
    else
        code = 1
    end if
end main
```

## Insertion sort

Insertion sort recursively grows a sorted prefix. An out-of-order value moves
left through adjacent swaps, so the example also exercises repeated computed
reads and writes to one fixed array.

Fixture source: `compiler/tests/fixtures/runtime/insertion-sort/main.ldn`.

```landin
--  The current kernel has recursion and fixed arrays, but no loops or
--  aggregate parameters yet.  This insertion sort therefore works recursively
--  over module storage.  The array literal is its static initial image.
mut values: [8]i32 = [9, -4, 7, 7, 0, -9, 42, 1]

insert_at: (at: usize) -> none =
    return when at == 0

    previous: usize = at - 1
    if values[previous] > values[at] then
        saved: i32 = values[previous]
        values[previous] = values[at]
        values[at] = saved
        insert_at(previous)
    end if
end insert_at

insertion_sort_from: (at: usize) -> none =
    return when at >= lenof values
    insert_at(at)
    insertion_sort_from(at + 1)
end insertion_sort_from

public main: () -> (code: i32) =
    insertion_sort_from(1)

    if values[0] == -9
        and values[1] == -4
        and values[2] == 0
        and values[3] == 1
        and values[4] == 7
        and values[5] == 7
        and values[6] == 9
        and values[7] == 42
    then
        code = 42
    else
        code = 1
    end if
end main
```

## Selection sort

Selection sort splits into two recursive jobs: find the least remaining value,
then put it at the front of the unsorted suffix. The duplicate threes make the
result check more than a permutation of distinct values.

Fixture source: `compiler/tests/fixtures/runtime/selection-sort/main.ldn`.

```landin
--  The current kernel has recursion and fixed arrays, but no loops or
--  aggregate parameters yet.  The search and outer pass are recursive, and
--  both operate on the module array initialized here.
mut values: [8]i32 = [18, 3, -5, 11, 3, 0, -20, 8]

minimum_from: (scan: usize, best: usize) -> (found: usize) =
    found = best

    if scan < lenof values then
        mut candidate: usize = best
        if values[scan] < values[best] then
            candidate = scan
        end if
        found = minimum_from(scan + 1, candidate)
    end if
end minimum_from

selection_sort_from: (at: usize) -> none =
    return when at >= lenof values

    smallest: usize = minimum_from(at + 1, at)
    saved: i32 = values[at]
    values[at] = values[smallest]
    values[smallest] = saved
    selection_sort_from(at + 1)
end selection_sort_from

public main: () -> (code: i32) =
    selection_sort_from(0)

    if values[0] == -20
        and values[1] == -5
        and values[2] == 0
        and values[3] == 3
        and values[4] == 3
        and values[5] == 8
        and values[6] == 11
        and values[7] == 18
    then
        code = 42
    else
        code = 1
    end if
end main
```

## Merge sort

Merge sort is the divide-and-conquer example. It recursively sorts two
half-open ranges, copies the range into a work array, then recursively merges
the two sorted runs back into the input.

Fixture source: `compiler/tests/fixtures/runtime/merge-sort/main.ldn`.

```landin
--  Merge sort gives the recursive kernel a divide-and-conquer example.  Until
--  aggregate parameters arrive, the input and work area are module storage.
mut values: [8]i32 = [-12, 5, 0, 99, 5, 2, -3, 18]
mut work: [8]i32

copy_to_work: (at: usize, right: usize) -> none =
    if at < right then
        work[at] = values[at]
        copy_to_work(at + 1, right)
    end if
end copy_to_work

merge_from: (destination: usize, left_at: usize, middle: usize,
             right_at: usize, right: usize) -> none =
    return when destination >= right

    if left_at < middle then
        if right_at >= right then
            values[destination] = work[left_at]
            merge_from(destination + 1, left_at + 1, middle,
                       right_at, right)
        elsif work[left_at] <= work[right_at] then
            values[destination] = work[left_at]
            merge_from(destination + 1, left_at + 1, middle,
                       right_at, right)
        else
            values[destination] = work[right_at]
            merge_from(destination + 1, left_at, middle,
                       right_at + 1, right)
        end if
    else
        values[destination] = work[right_at]
        merge_from(destination + 1, left_at, middle,
                   right_at + 1, right)
    end if
end merge_from

merge_sort_range: (left: usize, right: usize) -> none =
    if right - left > 1 then
        middle: usize = left + (right - left) / 2
        merge_sort_range(left, middle)
        merge_sort_range(middle, right)
        copy_to_work(left, right)
        merge_from(left, left, middle, middle, right)
    end if
end merge_sort_range

public main: () -> (code: i32) =
    merge_sort_range(0, lenof values)

    if values[0] == -12
        and values[1] == -3
        and values[2] == 0
        and values[3] == 2
        and values[4] == 5
        and values[5] == 5
        and values[6] == 18
        and values[7] == 99
    then
        code = 42
    else
        code = 1
    end if
end main
```
