max = Math.max;
min = Math.min;
floor = Math.floor;
abs = Math.abs;
trunc = Math.trunc;
f32 = (a) => a;
u32 = (a) => Math.trunc(a);
step = (a, b) => (b < a ? 0 : 1);

fn_count = (side) => (side * 2 + 4) * 2;

fn = (side, count, vertex_index) => {
  let a = trunc(vertex_index / count);
  let b = vertex_index % count;
  let count_2 = count / 2;
  let c = b % count_2;
  let d = trunc(b / count_2);
  let middle = (count_2 - 1) / 2;
  let near_end_1 = count_2 - 1.5;
  let near_end_2 = count_2 - 2;

  let x = max(0, min(side, floor(middle - abs((f32(b) - near_end_1) / 2))));
  let y = f32(
    min(d + 1, ((b + d + 1) % 2) + u32(step(near_end_2, f32(c))) + d) + a * 2,
  );

  return { x, y };
};

side = 8;
count = fn_count(side);
acc = [];
for (let i = 0; i < (count * side) / 2; i += 1) {
  let { x, y } = fn(side, count, i);
  acc.push(`${x},${y}`);
  console.log(`${i} (${x}, ${y})`);
}

cc = acc.join("|");

// ideal_cc === cc;
