import sys

with open('tweak/AntiCensor.m', 'r', encoding='utf-8') as f:
    code = f.read()

stack = []
in_str = False
in_char = False
in_line_comment = False
in_block_comment = False

line = 1
col = 1
errors = []

i = 0
n = len(code)
while i < n:
    c = code[i]
    if c == '\n':
        line += 1
        col = 1
        if in_line_comment:
            in_line_comment = False
        i += 1
        continue
    else:
        col += 1

    if in_line_comment:
        i += 1
        continue
    if in_block_comment:
        if c == '*' and i + 1 < n and code[i+1] == '/':
            in_block_comment = False
            i += 2
            continue
        i += 1
        continue

    if in_str:
        if c == '\\':
            i += 2
            continue
        if c == '"':
            in_str = False
        i += 1
        continue

    if in_char:
        if c == '\\':
            i += 2
            continue
        if c == "'":
            in_char = False
        i += 1
        continue

    if c == '/' and i + 1 < n:
        if code[i+1] == '/':
            in_line_comment = True
            i += 2
            continue
        elif code[i+1] == '*':
            in_block_comment = True
            i += 2
            continue

    if c == '"':
        in_str = True
        i += 1
        continue
    if c == "'":
        in_char = True
        i += 1
        continue

    if c in '{[(':
        stack.append((c, line, col))
    elif c in '}])':
        if not stack:
            errors.append(f'Unmatched closing {c} at {line}:{col}')
        else:
            top, tl, tc = stack.pop()
            matches = {'}': '{', ']': '[', ')': '('}
            if matches[c] != top:
                errors.append(f'Mismatched {c} at {line}:{col}, expected matching for {top} from {tl}:{tc}')
    i += 1

if stack:
    for top, tl, tc in stack[-5:]:
        errors.append(f'Unclosed {top} from line {tl}:{tc}')

print(f'Bracket check errors count: {len(errors)}')
for e in errors[:10]:
    print(e)
