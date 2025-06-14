! This file is part of tblite.
! SPDX-Identifier: LGPL-3.0-or-later
!
! tblite is free software: you can redistribute it and/or modify it under
! the terms of the GNU Lesser General Public License as published by
! the Free Software Foundation, either version 3 of the License, or
! (at your option) any later version.
!
! tblite is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
! GNU Lesser General Public License for more details.
!
! You should have received a copy of the GNU Lesser General Public License
! along with tblite.  If not, see <https://www.gnu.org/licenses/>.

!> Implementation of the driver entry points for the singlepoint runner
module tblite_driver_run
   use, intrinsic :: iso_fortran_env, only : output_unit, error_unit, input_unit
   use mctc_env, only : error_type, fatal_error, wp
   use mctc_io, only : structure_type, read_structure, filetype
   use mctc_io_constants, only : codata
   use mctc_io_convert, only : aatoau, ctoau
   use tblite_cli, only : run_config
   use tblite_basis_type, only : basis_type
   use tblite_container, only : container_type
   use tblite_context, only : context_type, context_terminal, escape
   use tblite_data_spin, only : get_spin_constant
   use tblite_external_field, only : electric_field
   use tblite_lapack_solver, only : lapack_solver
   use tblite_output_ascii
   use tblite_param, only : param_record
   use tblite_results, only : results_type
   use tblite_spin, only : spin_polarization, new_spin_polarization
   use tblite_solvation, only : new_solvation, new_solvation_cds, new_solvation_shift, solvation_type
   use tblite_wavefunction, only : wavefunction_type, new_wavefunction, &
      & sad_guess, eeq_guess, shell_partition, load_wavefunction, save_wavefunction
   use tblite_xtb_calculator, only : xtb_calculator, new_xtb_calculator
   use tblite_xtb_gfn2, only : new_gfn2_calculator, export_gfn2_param
   use tblite_xtb_gfn1, only : new_gfn1_calculator, export_gfn1_param
   use tblite_xtb_ipea1, only : new_ipea1_calculator, export_ipea1_param
   use tblite_xtb_singlepoint, only : xtb_singlepoint
   use tblite_ceh_singlepoint, only : ceh_singlepoint
   use tblite_ceh_ceh, only : new_ceh_calculator
   use tblite_post_processing_list, only : add_post_processing, post_processing_type, post_processing_list

   implicit none
   private

   public :: main

   interface main
      module procedure :: run_main
   end interface

   real(wp), parameter :: kt = 3.166808578545117e-06_wp
   real(wp), parameter :: jtoau = 1.0_wp / (codata%me*codata%c**2*codata%alpha**2)
   !> Convert V/Å = J/(C·Å) to atomic units
   real(wp), parameter :: vatoau = jtoau / (ctoau * aatoau)
   character(len=:), allocatable :: wbo_label, molmom_label

contains


subroutine run_main(config, error)
   type(run_config), intent(in) :: config
   type(error_type), allocatable, intent(out) :: error

   type(structure_type) :: mol
   character(len=:), allocatable :: method, filename
   integer :: unpaired, charge, unit, nspin
   logical :: restart_exist, use_guess
   real(wp) :: energy
   real(wp), allocatable :: dpmom(:), qpmom(:)
   real(wp), allocatable :: gradient(:, :), sigma(:, :)
   type(param_record) :: param
   type(context_type) :: ctx
   type(xtb_calculator) :: calc
   type(xtb_calculator) :: calc_ceh
   type(wavefunction_type) :: wfn, wfn_ceh
   type(results_type) :: results
   class(post_processing_list), allocatable :: post_proc

   ctx%terminal = context_terminal(config%color)
   ctx%solver = lapack_solver(config%solver)

   if (config%input == "-") then
      if (allocated(config%input_format)) then
         call read_structure(mol, input_unit, config%input_format, error)
      else
         call read_structure(mol, input_unit, filetype%xyz, error)
      end if
   else
      call read_structure(mol, config%input, error, config%input_format)
   end if
   if (allocated(error)) return

   if (allocated(config%charge)) then
      mol%charge = config%charge
   else
      filename = join(dirname(config%input), ".CHRG")
      if (exists(filename)) then
         call read_file(filename, charge, error)
         if (allocated(error)) return
         if (config%verbosity > 0) &
            & call info(ctx, "Molecular charge read from '"//filename//"'")
         mol%charge = charge
      end if
   end if
   if (allocated(error)) return

   if (allocated(config%spin)) then
      mol%uhf = config%spin
   else
      filename = join(dirname(config%input), ".UHF")
      if (exists(filename)) then
         call read_file(filename, unpaired, error)
         if (allocated(error)) return
         if (config%verbosity > 0) &
            & call info(ctx, "Molecular spin read from '"//filename//"'")
         mol%uhf = unpaired
      end if
   end if

   nspin = merge(2, 1, config%spin_polarized)

   if (config%grad) then
      allocate(gradient(3, mol%nat), sigma(3, 3))
   end if
   
   if (allocated(error)) return

   if (allocated(config%param)) then
      call param%load(config%param, error)
      if (.not. allocated(error)) then
         call new_xtb_calculator(calc, mol, param, error)
      end if
   else
      method = "gfn2"
      if (allocated(config%method)) method = config%method
      select case(method)
      case default
         call fatal_error(error, "Unknown method '"//method//"' requested")
      case("gfn2")
         call new_gfn2_calculator(calc, mol, error)
      case("gfn1")
         call new_gfn1_calculator(calc, mol, error)
      case("ipea1")
         call new_ipea1_calculator(calc, mol, error)
      end select
   end if
   if (allocated(error)) return

   if (allocated(config%max_iter)) calc%max_iter = config%max_iter

   use_guess = .true.
   restart_exist = .false.
   if (config%restart) restart_exist = exists(config%restart_file)
   if (restart_exist) then
      call load_wavefunction(wfn, config%restart_file, error, &
         & nat=mol%nat, nsh=calc%bas%nsh, nao=calc%bas%nao, nspin=nspin)
      if (allocated(error)) then
         call warn(ctx, error%message)
         deallocate(error)
         call new_wavefunction(wfn, mol%nat, calc%bas%nsh, calc%bas%nao, nspin, config%etemp * kt)
      else
         call info(ctx, "Restarting from wavefunction '"//config%restart_file//"'")
         use_guess = .false.
      end if
      wfn%kt = config%etemp * kt
   else
      call new_wavefunction(wfn, mol%nat, calc%bas%nsh, calc%bas%nao, nspin, config%etemp * kt)
   end if

   if (use_guess .and. config%guess == "ceh") then
      call new_ceh_calculator(calc_ceh, mol, error)
      if (allocated(error)) return
      call new_wavefunction(wfn_ceh, mol%nat, calc_ceh%bas%nsh, calc_ceh%bas%nao, 1, config%etemp_guess * kt)
   end if

   if (allocated(config%efield)) then
      block
         class(container_type), allocatable :: cont
         cont = electric_field(config%efield*vatoau)
         call calc%push_back(cont)
      end block
      if (use_guess .and. config%guess == "ceh") then
         block
         class(container_type), allocatable :: cont
         cont = electric_field(config%efield*vatoau)
         call calc_ceh%push_back(cont)
         end block
      end if
   end if

   if (use_guess) then
      select case(config%guess)
      case default
         call fatal_error(error, "Unknown starting guess '"//config%guess//"' requested")
      case("sad")
         call sad_guess(mol, calc, wfn)
      case("eeq")
         call eeq_guess(mol, calc, wfn)
      case("ceh")
         call ceh_singlepoint(ctx, calc_ceh, mol, wfn_ceh, config%accuracy, config%verbosity)
         if (ctx%failed()) then
            call fatal(ctx, "CEH singlepoint calculation failed")
            do while(ctx%failed())
               call ctx%get_error(error)
               write(error_unit, '("->", 1x, a)') error%message
            end do
            error stop
         end if
         wfn%qat(:, 1) = wfn_ceh%qat(:, 1)
         call shell_partition(mol, calc, wfn)
      end select
   end if
   if (allocated(error)) return

   if (config%spin_polarized) then
      block
         class(container_type), allocatable :: cont
         type(spin_polarization), allocatable :: spin
         real(wp), allocatable :: wll(:, :, :)
         allocate(spin)
         call get_spin_constants(wll, mol, calc%bas)
         call new_spin_polarization(spin, mol, wll, calc%bas%nsh_id)
         call move_alloc(spin, cont)
         call calc%push_back(cont)
      end block
   end if

   if (allocated(config%solvation)) then
      method = "gfn2"
      if (allocated(config%method)) method = config%method
      block
         class(container_type), allocatable :: cont
         class(solvation_type), allocatable :: solv
         call new_solvation(solv, mol, config%solvation, error, method)
         if (allocated(error)) return
         call move_alloc(solv, cont)
         call calc%push_back(cont)
      end block
      if (allocated(config%solvation%cds)) then
         block
            class(container_type), allocatable :: cont
            class(solvation_type), allocatable :: cds
            call new_solvation_cds(cds, mol, config%solvation, error, method)
            if (allocated(error)) return
            call move_alloc(cds, cont)
            call calc%push_back(cont)
         end block
      end if
      if (allocated(config%solvation%shift)) then
         block
            class(container_type), allocatable :: cont
            class(solvation_type), allocatable :: shift
            call new_solvation_shift(shift, config%solvation, error, method)
            if (allocated(error)) return
            call move_alloc(shift, cont)
            call calc%push_back(cont)
         end block
      end if
   end if

   wbo_label = "bond-orders"
   allocate(post_proc)
   call add_post_processing(post_proc, wbo_label, error)
   if (allocated(error)) return

   if (config%verbosity > 2) then
      molmom_label = "molmom"
      call add_post_processing(post_proc, molmom_label, error)
      if (allocated(error)) return
   end if

   if (allocated(config%post_processing)) then
      call add_post_processing(post_proc, config%post_processing, error)
      if (allocated(error)) return
   end if

   if (allocated(param%post_proc)) then
      call add_post_processing(post_proc, param%post_proc)
      if (allocated(error)) return
   end if

   if (config%verbosity > 0) then
      call ctx%message(calc%info(config%verbosity, " | "))
      call ctx%message("")
   end if

   call xtb_singlepoint(ctx, mol, calc, wfn, config%accuracy, energy, gradient, sigma, &
      & config%verbosity, results, post_proc)
   if (ctx%failed()) then
      call fatal(ctx, "Singlepoint calculation failed")
      do while(ctx%failed())
         call ctx%get_error(error)
         write(error_unit, '("->", 1x, a)') error%message
      end do
      error stop
   end if

   if (allocated(config%restart_file)) then
      call info(ctx, "Writing wavefunction information to '"//config%restart_file//"'")
      call save_wavefunction(wfn, config%restart_file, error)
      if (allocated(error)) return
   end if

   if (allocated(post_proc) .and. allocated(config%post_proc_output)) then
      call results%dict%dump(config%post_proc_output, error)
      if (allocated(error)) return
   end if

   if (config%verbosity > 2) then
      call ascii_levels(ctx%unit, config%verbosity, wfn%emo, wfn%focc, 7)
      call post_proc%dict%get_entry("molecular-dipole", dpmom)
      call post_proc%dict%get_entry("molecular-quadrupole", qpmom)
      
      call ascii_dipole_moments(ctx%unit, 1, mol, wfn%dpat(:, :, 1), dpmom)
      call ascii_quadrupole_moments(ctx%unit, 1, mol, wfn%qpat(:, :, 1), qpmom)
   end if

   deallocate(post_proc)

   if (allocated(config%grad_output)) then
      open(file=config%grad_output, newunit=unit)
      call tagged_result(unit, energy, gradient, sigma, energies=results%energies)
      close(unit)
      if (config%verbosity > 0) then
         call info(ctx, "Tight-binding results written to '"//config%grad_output//"'")
      end if
   end if

   if (config%json) then
      open(file=config%json_output, newunit=unit)
      call json_results(unit, "  ", energy=energy, gradient=gradient, sigma=sigma, &
         & energies=results%energies)
      close(unit)
      if (config%verbosity > 0) then
         call info(ctx, "JSON dump of results written to '"//config%json_output//"'")
      end if
   end if
end subroutine run_main


subroutine info(ctx, message)
   type(context_type), intent(inout) :: ctx
   character(len=*), intent(in) :: message

   call ctx%message( &
      & escape(ctx%terminal%bold) // "[" // &
      & escape(ctx%terminal%bold_cyan) // "Info" // &
      & escape(ctx%terminal%bold) // "]" // &
      & escape(ctx%terminal%reset) // " " // &
      & message)
end subroutine info


subroutine warn(ctx, message)
   type(context_type), intent(inout) :: ctx
   character(len=*), intent(in) :: message

   call ctx%message( &
      & escape(ctx%terminal%bold) // "[" // &
      & escape(ctx%terminal%bold_yellow) // "Warn" // &
      & escape(ctx%terminal%bold) // "]" // &
      & escape(ctx%terminal%reset) // " " // &
      & message)
end subroutine warn


subroutine fatal(ctx, message)
   type(context_type), intent(inout) :: ctx
   character(len=*), intent(in) :: message

   call ctx%message( &
      & escape(ctx%terminal%bold) // "[" // &
      & escape(ctx%terminal%bold_red) // "Fatal" // &
      & escape(ctx%terminal%bold) // "]" // &
      & escape(ctx%terminal%reset) // " " // &
      & message)
end subroutine fatal


subroutine get_spin_constants(wll, mol, bas)
   real(wp), allocatable, intent(out) :: wll(:, :, :)
   type(structure_type), intent(in) :: mol
   type(basis_type), intent(in) :: bas

   integer :: izp, ish, jsh, il, jl

   allocate(wll(bas%nsh, bas%nsh, mol%nid), source=0.0_wp)

   do izp = 1, mol%nid
      do ish = 1, bas%nsh_id(izp)
         il = bas%cgto(ish, izp)%ang
         do jsh = 1, bas%nsh_id(izp)
            jl = bas%cgto(jsh, izp)%ang
            wll(jsh, ish, izp) = get_spin_constant(jl, il, mol%num(izp))
         end do
      end do
   end do
end subroutine get_spin_constants


!> Extract dirname from path
function dirname(filename)
   character(len=*), intent(in) :: filename
   character(len=:), allocatable :: dirname

   dirname = filename(1:scan(filename, "/\", back=.true.))
   if (len_trim(dirname) == 0) dirname = "."
end function dirname


!> Construct path by joining strings with os file separator
function join(a1, a2) result(path)
   use mctc_env_system, only : is_windows
   character(len=*), intent(in) :: a1, a2
   character(len=:), allocatable :: path
   character :: filesep

   if (is_windows()) then
      filesep = '\'
   else
      filesep = '/'
   end if

   path = a1 // filesep // a2
end function join


!> test if pathname already exists
function exists(filename)
    character(len=*), intent(in) :: filename
    logical :: exists
    inquire(file=filename, exist=exists)
end function exists


subroutine read_file(filename, val, error)
   use mctc_io_utils, only : next_line, read_next_token, io_error, token_type
   character(len=*), intent(in) :: filename
   integer, intent(out) :: val
   type(error_type), allocatable, intent(out) :: error

   integer :: io, stat, lnum, pos
   type(token_type) :: token
   character(len=:), allocatable :: line

   lnum = 0

   open(file=filename, newunit=io, status='old', iostat=stat)
   if (stat /= 0) then
      call fatal_error(error, "Error: Could not open file '"//filename//"'")
      return
   end if

   call next_line(io, line, pos, lnum, stat)
   if (stat == 0) &
      call read_next_token(line, pos, token, val, stat)
   if (stat /= 0) then
      call io_error(error, "Cannot read value from file", line, token, &
         filename, lnum, "expected integer value")
      return
   end if

   close(io, iostat=stat)

end subroutine read_file


end module tblite_driver_run
