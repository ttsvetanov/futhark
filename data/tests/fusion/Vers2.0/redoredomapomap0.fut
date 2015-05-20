// --
// input {
//   [1.0,-4.0,-2.4]
// }
// output {
//   { 
//     -5.4
//   , [2.0,-3.0,-1.4]
//   , 8.4
//   , [4.0,-6.0,-2.8]
//   , 3.0
//   , [0.0,1.0,2.0]
//   }
// }
fun real mul2([real] x, int i) = x[i]*2.0
fun {real,[real],real,[real],real,[real]} main([real] arr) =
    let r1 = reduce(+, 0.0, arr) in
    let x  = map   (+1.0,   arr) in
    let r2 = reduce(*, 1.0, x  ) in
    let y  = map(mul2(x),   iota(size(0,x  ))) in
    let z  = map(toFloat64, iota(size(0,arr))) in
    let r3 = reduce(+, 0.0, z) in
    {r1,x,r2,y,r3,z}