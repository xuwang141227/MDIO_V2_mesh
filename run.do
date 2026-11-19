transcript on
if {[file exists work]} {
    vdel -lib work -all
}
vlib work
vlog -sv mdio_passthrough.v tb_mdio_passthrough.v
vsim -c work.tb_mdio_passthrough
run -all
quit -f
