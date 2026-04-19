let
  npv = import ./. { };
  ps = npv.packages.${builtins.currentSystem};
in
{
  python = ps.python3."3.14.3";
  hello = ps.hello."2.10";
}
